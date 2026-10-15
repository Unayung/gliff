//! Channels from the worker thread to the GTK thread that wake the GTK side
//! as soon as something arrives, instead of leaving it for a polling timer
//! (which cost up to a whole period of latency on every frame and status).
//! Each send, and each dropped sender, signals a `Notify` that the GTK
//! side's future awaits; it then drains the plain std channel as before.

use std::sync::mpsc::{self, SendError, TryRecvError, TrySendError};
use std::sync::Arc;

use tokio::sync::Notify;

pub fn channel<T>() -> (Sender<T>, Receiver<T>) {
    let (tx, rx) = mpsc::channel();
    let ready = Arc::new(Notify::new());
    (
        Sender {
            tx,
            ready: ready.clone(),
        },
        Receiver { rx, ready },
    )
}

/// A bounded channel; a full one refuses a send (the worker keeps the
/// frame for later, latest wins).
pub fn sync_channel<T>(bound: usize) -> (SyncSender<T>, Receiver<T>) {
    let (tx, rx) = mpsc::sync_channel(bound);
    let ready = Arc::new(Notify::new());
    (
        SyncSender {
            tx,
            ready: ready.clone(),
        },
        Receiver { rx, ready },
    )
}

pub struct Sender<T> {
    tx: mpsc::Sender<T>,
    ready: Arc<Notify>,
}

impl<T> Sender<T> {
    pub fn send(&self, value: T) -> Result<(), SendError<T>> {
        let sent = self.tx.send(value);
        self.ready.notify_one();
        sent
    }
}

impl<T> Clone for Sender<T> {
    fn clone(&self) -> Self {
        Self {
            tx: self.tx.clone(),
            ready: self.ready.clone(),
        }
    }
}

/// A sender going away may disconnect the channel, which the receiver must
/// see; a spurious wake costs one empty drain.
impl<T> Drop for Sender<T> {
    fn drop(&mut self) {
        self.ready.notify_one();
    }
}

pub struct SyncSender<T> {
    tx: mpsc::SyncSender<T>,
    ready: Arc<Notify>,
}

impl<T> SyncSender<T> {
    pub fn try_send(&self, value: T) -> Result<(), TrySendError<T>> {
        let sent = self.tx.try_send(value);
        if sent.is_ok() {
            self.ready.notify_one();
        }
        sent
    }
}

impl<T> Drop for SyncSender<T> {
    fn drop(&mut self) {
        self.ready.notify_one();
    }
}

pub struct Receiver<T> {
    rx: mpsc::Receiver<T>,
    ready: Arc<Notify>,
}

impl<T> Receiver<T> {
    pub fn try_recv(&self) -> Result<T, TryRecvError> {
        self.rx.try_recv()
    }

    /// Wait until something was sent or a sender dropped since the last
    /// wait; a send that came before this call returns at once.
    pub async fn ready(&self) {
        self.ready.notified().await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn block_on<F: std::future::Future>(f: F) -> F::Output {
        tokio::runtime::Builder::new_current_thread()
            .build()
            .unwrap()
            .block_on(f)
    }

    #[test]
    fn a_send_from_another_thread_wakes_the_waiter() {
        let (tx, rx) = channel::<u32>();
        let t = std::thread::spawn(move || {
            std::thread::sleep(std::time::Duration::from_millis(20));
            tx.send(7).unwrap();
            // Keep the sender so only the send can be the wake.
            std::thread::sleep(std::time::Duration::from_millis(50));
        });
        block_on(rx.ready());
        assert_eq!(rx.try_recv(), Ok(7));
        t.join().unwrap();
    }

    #[test]
    fn a_send_before_the_wait_is_not_lost() {
        let (tx, rx) = sync_channel::<u32>(1);
        tx.try_send(1).unwrap();
        block_on(rx.ready());
        assert_eq!(rx.try_recv(), Ok(1));
        drop(tx);
    }

    #[test]
    fn dropping_the_sender_wakes_with_disconnected() {
        let (tx, rx) = sync_channel::<u32>(1);
        drop(tx);
        block_on(rx.ready());
        assert_eq!(rx.try_recv(), Err(TryRecvError::Disconnected));
    }
}
