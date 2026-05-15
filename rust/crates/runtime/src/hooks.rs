use std::ffi::OsStr;
use std::fmt::Write as FmtWrite;
use std::io::Write;
use std::process::{Command, Stdio};
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc,
};
use std::thread;
use std::time::{Duration, Instant};

use serde_json::{json, Value};

use crate::config::{RuntimeFeatureConfig, RuntimeHookConfig};
use crate::permissions::PermissionOverride;

const HOOK_PREVIEW_CHAR_LIMIT: usize = 160;

pub type HookPermissionDecision = PermissionOverride;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HookEvent {
    PreToolUse,
    PostToolUse,
    PostToolUseFailure,
}

impl HookEvent {
    #[must_use]
    pub fn as_str(self) -> &'static str {
        match self {
            Self::PreToolUse => "PreToolUse",
            Self::PostToolUse => "PostToolUse",
            Self::PostToolUseFailure => "PostToolUseFailure",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HookProgressEvent {
    Started {
        event: HookEvent,
        tool_name: String,
        command: String,
    },
    Completed {
        event: HookEvent,
        tool_name: String,
        command: String,
    },
    Cancelled {
        event: HookEvent,
        tool_name: String,
        command: String,
    },
}

pub trait HookProgressReporter {
    fn on_event(&mut self, event: &HookProgressEvent);
}

#[derive(Debug, Clone, Default)]
pub struct HookAbortSignal {
    aborted: Arc<AtomicBool>,
}

impl HookAbortSignal {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    pub fn abort(&self) {
        self.aborted.store(true, Ordering::SeqCst);
    }

    #[must_use]
    pub fn is_aborted(&self) -> bool {
        self.aborted.load(Ordering::SeqCst)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HookRunResult {
    denied: bool,
    failed: bool,
    cancelled: bool,
    messages: Vec<String>,
    permission_override: Option<PermissionOverride>,
    permission_reason: Option<String>,
    updated_input: Option<String>,
}

impl HookRunResult {
    #[must_use]
    pub fn allow(messages: Vec<String>) -> Self {
        Self {
            denied: false,
            failed: false,
            cancelled: false,
            messages,
            permission_override: None,
            permission_reason: None,
            updated_input: None,
        }
    }

    #[must_use]
    pub fn is_denied(&self) -> bool {
        self.denied
    }

    #[must_use]
    pub fn is_failed(&self) -> bool {
        self.failed
    }

    #[must_use]
    pub fn is_cancelled(&self) -> bool {
        self.cancelled
    }

    #[must_use]
    pub fn messages(&self) -> &[String] {
        &self.messages
    }

    #[must_use]
    pub fn permission_override(&self) -> Option<PermissionOverride> {
        self.permission_override
    }

    #[must_use]
    pub fn permission_decision(&self) -> Option<HookPermissionDecision> {
        self.permission_override
    }

    #[must_use]
    pub fn permission_reason(&self) -> Option<&str> {
        self.permission_reason.as_deref()
    }

    #[must_use]
    pub fn updated_input(&self) -> Option<&str> {
        self.updated_input.as_deref()
    }

    #[must_use]
    pub fn updated_input_json(&self) -> Option<&str> {
        self.updated_input()
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct HookRunner {
    config: RuntimeHookConfig,
    stream_debug_hooks: Vec<Box<dyn HookStreamDebugger>>,
}

impl HookRunner {
    #[must_use]
    pub fn new(config: RuntimeHookConfig) -> Self {
        Self { 
            config,
            stream_debug_hooks: Vec::new(),
        }
    }

    /// Set stream debugging hooks for monitoring stream lifecycle events
    #[must_use]
    pub fn with_stream_debug_hooks(mut self, hooks: Vec<Box<dyn crate::hooks::HookStreamDebugger>>) -> Self {
        self.stream_debug_hooks = hooks;
        self
    }

    #[must_use]
    pub fn from_feature_config(feature_config: &RuntimeFeatureConfig) -> Self {
        Self::new(feature_config.hooks().clone())
    }

    #[must_use]
    pub fn run_pre_tool_use(&self, tool_name: &str, tool_input: &str) -> HookRunResult {
        self.run_pre_tool_use_with_context(tool_name, tool_input, None, None)
    }

    #[must_use]
    pub fn run_pre_tool_use_with_context(
        &self,
        tool_name: &str,
        tool_input: &str,
        abort_signal: Option<&HookAbortSignal>,
        reporter: Option<&mut dyn HookProgressReporter>,
    ) -> HookRunResult {
        Self::run_commands(
            HookEvent::PreToolUse,
            self.config.pre_tool_use(),
            tool_name,
            tool_input,
            None,
            false,
            abort_signal,
            reporter,
        )
    }

    #[must_use]
    pub fn run_pre_tool_use_with_signal(
        &self,
        tool_name: &str,
        tool_input: &str,
        abort_signal: Option<&HookAbortSignal>,
    ) -> HookRunResult {
        self.run_pre_tool_use_with_context(tool_name, tool_input, abort_signal, None)
    }

    #[must_use]
    pub fn run_post_tool_use(
        &self,
        tool_name: &str,
        tool_input: &str,
        tool_output: &str,
        is_error: bool,
    ) -> HookRunResult {
        self.run_post_tool_use_with_context(
            tool_name,
            tool_input,
            tool_output,
            is_error,
            None,
            None,
        )
    }

    #[must_use]
    pub fn run_post_tool_use_with_context(
        &self,
        tool_name: &str,
        tool_input: &str,
        tool_output: &str,
        is_error: bool,
        abort_signal: Option<&HookAbortSignal>,
        reporter: Option<&mut dyn HookProgressReporter>,
    ) -> HookRunResult {
        Self::run_commands(
            HookEvent::PostToolUse,
            self.config.post_tool_use(),
            tool_name,
            tool_input,
            Some(tool_output),
            is_error,
            abort_signal,
            reporter,
        )
    }

    #[must_use]
    pub fn run_post_tool_use_with_signal(
        &self,
        tool_name: &str,
        tool_input: &str,
        tool_output: &str,
        is_error: bool,
        abort_signal: Option<&HookAbortSignal>,
    ) -> HookRunResult {
        self.run_post_tool_use_with_context(
            tool_name,
            tool_input,
            tool_output,
            is_error,
            abort_signal,
            None,
        )
    }

    #[must_use]
    pub fn run_post_tool_use_failure(
        &self,
        tool_name: &str,
        tool_input: &str,
        tool_error: &str,
    ) -> HookRunResult {
        self.run_post_tool_use_failure_with_context(tool_name, tool_input, tool_error, None, None)
    }

    #[must_use]
    pub fn run_post_tool_use_failure_with_context(
        &self,
        tool_name: &str,
        tool_input: &str,
        tool_error: &str,
        abort_signal: Option<&HookAbortSignal>,
        reporter: Option<&mut dyn HookProgressReporter>,
    ) -> HookRunResult {
        Self::run_commands(
            HookEvent::PostToolUseFailure,
            self.config.post_tool_use_failure(),
            tool_name,
            tool_input,
            Some(tool_error),
            true,
            abort_signal,
            reporter,
        )
    }

    #[must_use]
    pub fn run_post_tool_use_failure_with_signal(
        &self,
        tool_name: &str,
        tool_input: &str,
        tool_error: &str,
        abort_signal: Option<&HookAbortSignal>,
    ) -> HookRunResult {
        self.run_post_tool_use_failure_with_context(
            tool_name,
            tool_input,
            tool_error,
            abort_signal,
            None,
        )
    }
}
        let result = runner.run_pre_tool_use("Read", r#"{"path":"README.md"}"#);

        assert_eq!(result, HookRunResult::allow(vec!["pre ok".to_string()]));
    }

    #[test]
    fn denies_exit_code_two() {
        let runner = HookRunner::new(RuntimeHookConfig::new(
            vec![shell_snippet("printf 'blocked by hook'; exit 2")],
            Vec::new(),
            Vec::new(),
        ));

        let result = runner.run_pre_tool_use("Bash", r#"{"command":"pwd"}"#);

        assert!(result.is_denied());
        assert_eq!(result.messages(), &["blocked by hook".to_string()]);
    }

    #[test]
    fn propagates_other_non_zero_statuses_as_failures() {
        let runner = HookRunner::from_feature_config(&RuntimeFeatureConfig::default().with_hooks(
            RuntimeHookConfig::new(
                vec![shell_snippet("printf 'warning hook'; exit 1")],
                Vec::new(),
                Vec::new(),
            ),
        ));

        // given
        // when
        let result = runner.run_pre_tool_use("Edit", r#"{"file":"src/lib.rs"}"#);

        // then
        assert!(result.is_failed());
        assert!(result
            .messages()
            .iter()
            .any(|message| message.contains("warning hook")));
    }

    #[test]
    fn parses_pre_hook_permission_override_and_updated_input() {
        let runner = HookRunner::new(RuntimeHookConfig::new(
            vec![shell_snippet(
                r#"printf '%s' '{"systemMessage":"updated","hookSpecificOutput":{"permissionDecision":"allow","permissionDecisionReason":"hook ok","updatedInput":{"command":"git status"}}}'"#,
            )],
            Vec::new(),
            Vec::new(),
        ));

        let result = runner.run_pre_tool_use("bash", r#"{"command":"pwd"}"#);

        assert_eq!(
            result.permission_override(),
            Some(PermissionOverride::Allow)
        );
        assert_eq!(result.permission_reason(), Some("hook ok"));
        assert_eq!(result.updated_input(), Some(r#"{"command":"git status"}"#));
        assert!(result.messages().iter().any(|message| message == "updated"));
    }

    #[test]
    fn runs_post_tool_use_failure_hooks() {
        // given
        let runner = HookRunner::new(RuntimeHookConfig::new(
            Vec::new(),
            Vec::new(),
            vec![shell_snippet("printf 'failure hook ran'")],
        ));

        // when
        let result =
            runner.run_post_tool_use_failure("bash", r#"{"command":"false"}"#, "command failed");

        // then
        assert!(!result.is_denied());
        assert_eq!(result.messages(), &["failure hook ran".to_string()]);
    }

    #[test]
    fn stops_running_failure_hooks_after_failure() {
        // given
        let runner = HookRunner::new(RuntimeHookConfig::new(
            Vec::new(),
            Vec::new(),
            vec![
                shell_snippet("printf 'broken failure hook'; exit 1"),
                shell_snippet("printf 'later failure hook'"),
            ],
        ));

        // when
        let result =
            runner.run_post_tool_use_failure("bash", r#"{"command":"false"}"#, "command failed");

        // then
        assert!(result.is_failed());
        assert!(result
            .messages()
            .iter()
            .any(|message| message.contains("broken failure hook")));
        assert!(!result
            .messages()
            .iter()
            .any(|message| message == "later failure hook"));
    }

    #[test]
    fn executes_hooks_in_configured_order() {
        // given
        let runner = HookRunner::new(RuntimeHookConfig::new(
            vec![
                shell_snippet("printf 'first'"),
                shell_snippet("printf 'second'"),
            ],
            Vec::new(),
            Vec::new(),
        ));
        let mut reporter = RecordingReporter { events: Vec::new() };

        // when
        let result = runner.run_pre_tool_use_with_context(
            "Read",
            r#"{"path":"README.md"}"#,
            None,
            Some(&mut reporter),
        );

        // then
        assert_eq!(
            result,
            HookRunResult::allow(vec!["first".to_string(), "second".to_string()])
        );
        assert_eq!(reporter.events.len(), 4);
        assert!(matches!(
            &reporter.events[0],
            HookProgressEvent::Started {
                event: HookEvent::PreToolUse,
                command,
                ..
            } if command == "printf 'first'"
        ));
        assert!(matches!(
            &reporter.events[1],
            HookProgressEvent::Completed {
                event: HookEvent::PreToolUse,
                command,
                ..
            } if command == "printf 'first'"
        ));
        assert!(matches!(
            &reporter.events[2],
            HookProgressEvent::Started {
                event: HookEvent::PreToolUse,
                command,
                ..
            } if command == "printf 'second'"
        ));
        assert!(matches!(
            &reporter.events[3],
            HookProgressEvent::Completed {
                event: HookEvent::PreToolUse,
                command,
                ..
            } if command == "printf 'second'"
        ));
    }

    #[test]
    fn stops_running_hooks_after_failure() {
        // given
        let runner = HookRunner::new(RuntimeHookConfig::new(
            vec![
                shell_snippet("printf 'broken'; exit 1"),
                shell_snippet("printf 'later'"),
            ],
            Vec::new(),
            Vec::new(),
        ));

        // when
        let result = runner.run_pre_tool_use("Edit", r#"{"file":"src/lib.rs"}"#);

        // then
        assert!(result.is_failed());
        assert!(result
            .messages()
            .iter()
            .any(|message| message.contains("broken")));
        assert!(!result.messages().iter().any(|message| message == "later"));
    }

    #[test]
    fn malformed_nonempty_hook_output_reports_explicit_diagnostic_with_previews() {
        let runner = HookRunner::new(RuntimeHookConfig::new(
            vec![shell_snippet(
                "printf '{not-json\nsecond line'; printf 'stderr warning' >&2; exit 1",
            )],
            Vec::new(),
            Vec::new(),
        ));

        let result = runner.run_pre_tool_use("Edit", r#"{"file":"src/lib.rs"}"#);

        assert!(result.is_failed());
        let rendered = result.messages().join("\n");
        assert!(rendered.contains("hook_invalid_json:"));
        assert!(rendered.contains("phase=PreToolUse"));
        assert!(rendered.contains("tool=Edit"));
        assert!(rendered.contains("command=printf '{not-json"));
        assert!(rendered.contains("printf 'stderr warning' >&2; exit 1"));
        assert!(rendered.contains("detail=key must be a string"));
        assert!(rendered.contains("stdout_preview={not-json"));
        assert!(rendered.contains("second line stderr_preview=stderr warning"));
        assert!(rendered.contains("stderr_preview=stderr warning"));
    }

    #[test]
    fn abort_signal_cancels_long_running_hook_and_reports_progress() {
        let runner = HookRunner::new(RuntimeHookConfig::new(
            vec![shell_snippet("sleep 5")],
            Vec::new(),
            Vec::new(),
        ));
        let abort_signal = HookAbortSignal::new();
        let abort_signal_for_thread = abort_signal.clone();
        let mut reporter = RecordingReporter { events: Vec::new() };

        thread::spawn(move || {
            thread::sleep(Duration::from_millis(100));
            abort_signal_for_thread.abort();
        });

        let result = runner.run_pre_tool_use_with_context(
            "bash",
            r#"{"command":"sleep 5"}"#,
            Some(&abort_signal),
            Some(&mut reporter),
        );

        assert!(result.is_cancelled());
        assert!(reporter.events.iter().any(|event| matches!(
            event,
            HookProgressEvent::Started {
                event: HookEvent::PreToolUse,
                ..
            }
        )));
        assert!(reporter.events.iter().any(|event| matches!(
            event,
            HookProgressEvent::Cancelled {
                event: HookEvent::PreToolUse,
                ..
            }
        )));
    }

    // ============================================================================
    // Stream Debugging Hooks - For tracing and debugging API stream issues
    // ============================================================================

    use std::time::Instant;

    /// Context passed to stream debugging hooks for tracking stream lifecycle
    #[derive(Debug, Clone)]
    pub struct StreamDebugContext {
        pub request_id: Option<String>,
        pub model: String,
        pub attempt: u32,
        pub resilience_enabled: bool,
        pub context_usage_percent: Option<f32>,
        pub consecutive_failures: usize,
        pub tokens_produced_so_far: Option<u32>,
    }

    impl StreamDebugContext {
        #[must_use]
        pub fn new(model: String, attempt: u32) -> Self {
            Self {
                request_id: None,
                model,
                attempt,
                resilience_enabled: false,
                context_usage_percent: None,
                consecutive_failures: 0,
                tokens_produced_so_far: None,
            }
        }

        #[must_use]
        pub fn with_request_id(mut self, request_id: impl Into<String>) -> Self {
            self.request_id = Some(request_id.into());
            self
        }

        #[must_use]
        pub fn with_resilience_enabled(mut self, enabled: bool) -> Self {
            self.resilience_enabled = enabled;
            self
        }

        #[must_use]
        pub fn with_context_usage_percent(mut self, percent: f32) -> Self {
            self.context_usage_percent = Some(percent);
            self
        }

        #[must_use]
        pub fn with_consecutive_failures(mut self, failures: usize) -> Self {
            self.consecutive_failures = failures;
            self
        }

        #[must_use]
        pub fn with_tokens_produced(mut self, tokens: u32) -> Self {
            self.tokens_produced_so_far = Some(tokens);
            self
        }
    }

    /// Result of a stream operation for debugging
    #[derive(Debug, Clone)]
    pub struct StreamResult {
        pub events_produced: usize,
        pub tokens_produced: Option<u32>,
        pub duration: Duration,
        pub success: bool,
    }

    impl StreamResult {
        #[must_use]
        pub fn new(events_produced: usize, success: bool) -> Self {
            Self {
                events_produced,
                tokens_produced: None,
                duration: Duration::ZERO,
                success,
            }
        }

        #[must_use]
        pub fn with_tokens(mut self, tokens: u32) -> Self {
            self.tokens_produced = Some(tokens);
            self
        }

        #[must_use]
        pub fn with_duration(mut self, duration: Duration) -> Self {
            self.duration = duration;
            self
        }
    }

    /// Trait for stream debugging hooks - allows monitoring and logging of stream lifecycle events
    pub trait HookStreamDebugger {
        /// Called when a stream starts
        fn on_stream_start(
            &mut self,
            request: &MessageRequest,
            context: &StreamDebugContext,
        ) -> HookRunResult;

        /// Called for each chunk received during streaming
        fn on_stream_chunk(
            &mut self,
            chunk: &[u8],
            context: &StreamDebugContext,
        ) -> HookRunResult;

        /// Called when a stream completes (successfully or not)
        fn on_stream_end(
            &mut self,
            result: &StreamResult,
            context: &StreamDebugContext,
        ) -> HookRunResult;

        /// Called when a stream error occurs
        fn on_stream_error(
            &mut self,
            error: &ApiError,
            context: &StreamDebugContext,
        ) -> HookRunResult;
    }

    /// Default executor for stream debugging hooks - captures debug info for testing
    #[derive(Default)]
    pub struct StreamDebugExecutor {
        captured_starts: Vec<StreamDebugCapture>,
        captured_chunks: Vec<StreamDebugCapture>,
        captured_ends: Vec<StreamDebugCapture>,
        captured_errors: Vec<StreamDebugCapture>,
        start_time: Option<Instant>,
    }

    impl StreamDebugExecutor {
        #[must_use]
        pub fn new() -> Self {
            Self::default()
        }

        #[must_use]
        pub fn captured_starts(&self) -> &[StreamDebugCapture] {
            &self.captured_starts
        }

        #[must_use]
        pub fn captured_chunks(&self) -> &[StreamDebugCapture] {
            &self.captured_chunks
        }

        #[must_use]
        pub fn captured_ends(&self) -> &[StreamDebugCapture] {
            &self.captured_ends
        }

        #[must_use]
        pub fn captured_errors(&self) -> &[StreamDebugCapture] {
            &self.captured_errors
        }
    }

    /// Capture of a stream debugging event
    #[derive(Debug, Clone)]
    pub struct StreamDebugCapture {
        pub timestamp: Instant,
        pub model: String,
        pub attempt: u32,
        pub event_type: StreamDebugEventType,
    }

    #[derive(Debug, Clone)]
    pub enum StreamDebugEventType {
        Start { request_model: String },
        Chunk { chunk_size: usize },
        End { result: StreamResult },
        Error { error_message: String },
    }

    impl HookStreamDebugger for StreamDebugExecutor {
        fn on_stream_start(
            &mut self,
            request: &MessageRequest,
            context: &StreamDebugContext,
        ) -> HookRunResult {
            let capture = StreamDebugCapture {
                timestamp: Instant::now(),
                model: context.model.clone(),
                attempt: context.attempt,
                event_type: StreamDebugEventType::Start {
                    request_model: request.model.clone(),
                },
            };
            self.captured_starts.push(capture);
            HookRunResult::allow(vec![])
        }

        fn on_stream_chunk(
            &mut self,
            chunk: &[u8],
            context: &StreamDebugContext,
        ) -> HookRunResult {
            let capture = StreamDebugCapture {
                timestamp: Instant::now(),
                model: context.model.clone(),
                attempt: context.attempt,
                event_type: StreamDebugEventType::Chunk { chunk_size: chunk.len() },
            };
            self.captured_chunks.push(capture);
            HookRunResult::allow(vec![])
        }

        fn on_stream_end(
            &mut self,
            result: &StreamResult,
            context: &StreamDebugContext,
        ) -> HookRunResult {
            let capture = StreamDebugCapture {
                timestamp: Instant::now(),
                model: context.model.clone(),
                attempt: context.attempt,
                event_type: StreamDebugEventType::End { result: result.clone() },
            };
            self.captured_ends.push(capture);
            HookRunResult::allow(vec![])
        }

        fn on_stream_error(
            &mut self,
            error: &ApiError,
            context: &StreamDebugContext,
        ) -> HookRunResult {
            let capture = StreamDebugCapture {
                timestamp: Instant::now(),
                model: context.model.clone(),
                attempt: context.attempt,
                event_type: StreamDebugEventType::Error {
                    error_message: error.to_string(),
                },
            };
            self.captured_errors.push(capture);
            HookRunResult::allow(vec![])
        }
    }

    #[cfg(windows)]
    fn shell_snippet(script: &str) -> String {
        script.replace('\'', "\"")
    }

    #[cfg(not(windows))]
    fn shell_snippet(script: &str) -> String {
        script.to_string()
    }
}
