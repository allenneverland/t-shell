use std::{collections::HashMap, process::Command, sync::Arc};

use tokio::{
    sync::{mpsc, oneshot, Mutex},
    time::{timeout, Duration, Instant},
};

use crate::tmux::TmuxError;

const DEFAULT_DISPATCH_QUEUE_CAPACITY: usize = 256;
const MAX_BATCH_KEYS: usize = 32;
const COALESCE_WINDOW: Duration = Duration::from_millis(8);

fn run_send_keys<S: AsRef<str>>(target: &str, args: &[S]) -> Result<(), TmuxError> {
    let mut full_args: Vec<String> = vec![
        "send-keys".to_string(),
        "-t".to_string(),
        target.to_string(),
    ];
    for arg in args {
        full_args.push(arg.as_ref().to_string());
    }

    let output = Command::new("tmux")
        .args(full_args)
        .output()
        .map_err(TmuxError::Io)?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(TmuxError::Command(stderr.to_string()));
    }

    Ok(())
}

pub fn send_keys(target: &str, text: &str) -> Result<(), TmuxError> {
    run_send_keys(target, &["-l", text])?;
    run_send_keys(target, &["Enter"])?;
    Ok(())
}

pub fn send_escape(target: &str) -> Result<(), TmuxError> {
    run_send_keys(target, &["Escape"])
}

pub fn send_key(target: &str, key: &str) -> Result<(), TmuxError> {
    run_send_keys(target, &[key])
}

pub fn send_key_batch(target: &str, keys: &[String]) -> Result<(), TmuxError> {
    if keys.is_empty() {
        return Ok(());
    }
    run_send_keys(target, keys)
}

#[derive(Debug, thiserror::Error)]
pub enum KeyDispatchError {
    #[error("key dispatch queue is full")]
    QueueFull,
    #[error("key dispatch service unavailable")]
    Unavailable,
    #[error("tmux key dispatch failed: {0}")]
    Tmux(String),
}

#[derive(Clone)]
pub struct KeyDispatchService {
    inner: Arc<KeyDispatchInner>,
}

struct KeyDispatchInner {
    queue_capacity: usize,
    target_channels: Mutex<HashMap<String, mpsc::Sender<KeyDispatchMessage>>>,
}

struct KeyDispatchMessage {
    keys: Vec<String>,
    completion: Option<oneshot::Sender<Result<(), String>>>,
}

impl KeyDispatchService {
    pub fn new(queue_capacity: usize) -> Self {
        let queue_capacity = queue_capacity.max(1);
        Self {
            inner: Arc::new(KeyDispatchInner {
                queue_capacity,
                target_channels: Mutex::new(HashMap::new()),
            }),
        }
    }

    pub fn with_default_queue_capacity() -> Self {
        Self::new(DEFAULT_DISPATCH_QUEUE_CAPACITY)
    }

    pub async fn dispatch_keys(
        &self,
        target: String,
        keys: Vec<String>,
    ) -> Result<(), KeyDispatchError> {
        if keys.is_empty() {
            return Ok(());
        }
        let sender = self.sender_for_target(&target).await;
        let (completion_tx, completion_rx) = oneshot::channel();
        sender
            .try_send(KeyDispatchMessage {
                keys,
                completion: Some(completion_tx),
            })
            .map_err(|e| map_send_error(e))?;
        match completion_rx.await {
            Ok(Ok(())) => Ok(()),
            Ok(Err(message)) => Err(KeyDispatchError::Tmux(message)),
            Err(_) => Err(KeyDispatchError::Unavailable),
        }
    }

    pub async fn enqueue_keys(
        &self,
        target: String,
        keys: Vec<String>,
    ) -> Result<(), KeyDispatchError> {
        if keys.is_empty() {
            return Ok(());
        }
        let sender = self.sender_for_target(&target).await;
        sender
            .try_send(KeyDispatchMessage {
                keys,
                completion: None,
            })
            .map_err(|e| map_send_error(e))
    }

    async fn sender_for_target(&self, target: &str) -> mpsc::Sender<KeyDispatchMessage> {
        let mut channels = self.inner.target_channels.lock().await;
        if let Some(sender) = channels.get(target) {
            if !sender.is_closed() {
                return sender.clone();
            }
            channels.remove(target);
        }

        let (tx, rx) = mpsc::channel(self.inner.queue_capacity);
        channels.insert(target.to_string(), tx.clone());
        tokio::spawn(run_target_dispatch_loop(target.to_string(), rx));
        tx
    }
}

impl Default for KeyDispatchService {
    fn default() -> Self {
        Self::with_default_queue_capacity()
    }
}

fn map_send_error(err: mpsc::error::TrySendError<KeyDispatchMessage>) -> KeyDispatchError {
    match err {
        mpsc::error::TrySendError::Full(_) => KeyDispatchError::QueueFull,
        mpsc::error::TrySendError::Closed(_) => KeyDispatchError::Unavailable,
    }
}

async fn run_target_dispatch_loop(target: String, mut rx: mpsc::Receiver<KeyDispatchMessage>) {
    while let Some(first) = rx.recv().await {
        let mut messages = vec![first];
        let mut queued_keys = messages[0].keys.len();
        let deadline = Instant::now() + COALESCE_WINDOW;

        while queued_keys < MAX_BATCH_KEYS {
            let now = Instant::now();
            if now >= deadline {
                break;
            }
            let wait_time = deadline.saturating_duration_since(now);
            match timeout(wait_time, rx.recv()).await {
                Ok(Some(next)) => {
                    queued_keys += next.keys.len();
                    messages.push(next);
                }
                Ok(None) | Err(_) => break,
            }
        }

        let mut all_keys = Vec::with_capacity(queued_keys);
        for message in &messages {
            all_keys.extend(message.keys.iter().cloned());
        }

        let dispatch_result =
            dispatch_key_chunks(&target, &all_keys).map_err(|error| error.to_string());
        if let Err(error) = &dispatch_result {
            tracing::warn!(
                target = %target,
                error = %error,
                "failed to dispatch tmux key batch"
            );
        }

        for message in messages {
            if let Some(completion) = message.completion {
                let _ = completion.send(dispatch_result.clone());
            }
        }
    }
}

fn dispatch_key_chunks(target: &str, keys: &[String]) -> Result<(), TmuxError> {
    for chunk in keys.chunks(MAX_BATCH_KEYS) {
        send_key_batch(target, chunk)?;
    }
    Ok(())
}
