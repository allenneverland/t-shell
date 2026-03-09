use serde::Serialize;
use std::{
    fmt::Write,
    sync::atomic::{AtomicU64, Ordering},
};

const LATENCY_BUCKET_BOUNDS_MS: [u64; 10] = [
    100, 250, 500, 1_000, 2_000, 3_000, 5_000, 10_000, 20_000, 30_000,
];
const LATENCY_BUCKET_COUNT: usize = 11;

pub struct Metrics {
    pub events_bell_total: AtomicU64,
    pub events_agent_total: AtomicU64,
    pub apns_sent_total: AtomicU64,
    pub apns_failed_total: AtomicU64,
    pub invalid_token_removed_total: AtomicU64,
    pub invalid_token_detected_total: AtomicU64,
    pub notification_tap_total: AtomicU64,
    pub route_success_total: AtomicU64,
    pub route_fallback_total: AtomicU64,
    pub event_to_apns_latency_ms_total: AtomicU64,
    pub event_to_apns_latency_samples: AtomicU64,
    event_to_apns_latency_bucket_counts: [AtomicU64; LATENCY_BUCKET_COUNT],
}

impl Default for Metrics {
    fn default() -> Self {
        Self {
            events_bell_total: AtomicU64::new(0),
            events_agent_total: AtomicU64::new(0),
            apns_sent_total: AtomicU64::new(0),
            apns_failed_total: AtomicU64::new(0),
            invalid_token_removed_total: AtomicU64::new(0),
            invalid_token_detected_total: AtomicU64::new(0),
            notification_tap_total: AtomicU64::new(0),
            route_success_total: AtomicU64::new(0),
            route_fallback_total: AtomicU64::new(0),
            event_to_apns_latency_ms_total: AtomicU64::new(0),
            event_to_apns_latency_samples: AtomicU64::new(0),
            event_to_apns_latency_bucket_counts: std::array::from_fn(|_| AtomicU64::new(0)),
        }
    }
}

#[derive(Debug, Serialize)]
pub struct MetricsSnapshot {
    pub events_bell_total: u64,
    pub events_agent_total: u64,
    pub apns_sent_total: u64,
    pub apns_failed_total: u64,
    pub invalid_token_removed_total: u64,
    pub invalid_token_detected_total: u64,
    pub notification_tap_total: u64,
    pub route_success_total: u64,
    pub route_fallback_total: u64,
    pub event_to_apns_latency_ms_total: u64,
    pub event_to_apns_latency_samples: u64,
    pub event_to_apns_latency_bucket_le_ms: Vec<u64>,
    pub event_to_apns_latency_bucket_counts: Vec<u64>,
}

impl Metrics {
    pub fn snapshot(&self) -> MetricsSnapshot {
        MetricsSnapshot {
            events_bell_total: self.events_bell_total.load(Ordering::Relaxed),
            events_agent_total: self.events_agent_total.load(Ordering::Relaxed),
            apns_sent_total: self.apns_sent_total.load(Ordering::Relaxed),
            apns_failed_total: self.apns_failed_total.load(Ordering::Relaxed),
            invalid_token_removed_total: self.invalid_token_removed_total.load(Ordering::Relaxed),
            invalid_token_detected_total: self.invalid_token_detected_total.load(Ordering::Relaxed),
            notification_tap_total: self.notification_tap_total.load(Ordering::Relaxed),
            route_success_total: self.route_success_total.load(Ordering::Relaxed),
            route_fallback_total: self.route_fallback_total.load(Ordering::Relaxed),
            event_to_apns_latency_ms_total: self
                .event_to_apns_latency_ms_total
                .load(Ordering::Relaxed),
            event_to_apns_latency_samples: self
                .event_to_apns_latency_samples
                .load(Ordering::Relaxed),
            event_to_apns_latency_bucket_le_ms: LATENCY_BUCKET_BOUNDS_MS.to_vec(),
            event_to_apns_latency_bucket_counts: self
                .event_to_apns_latency_bucket_counts
                .iter()
                .map(|bucket| bucket.load(Ordering::Relaxed))
                .collect(),
        }
    }

    pub fn observe_latency_ms(&self, ms: u64) {
        self.event_to_apns_latency_ms_total
            .fetch_add(ms, Ordering::Relaxed);
        self.event_to_apns_latency_samples
            .fetch_add(1, Ordering::Relaxed);

        for (index, bound) in LATENCY_BUCKET_BOUNDS_MS.iter().enumerate() {
            if ms <= *bound {
                self.event_to_apns_latency_bucket_counts[index].fetch_add(1, Ordering::Relaxed);
            }
        }
        self.event_to_apns_latency_bucket_counts[LATENCY_BUCKET_COUNT - 1]
            .fetch_add(1, Ordering::Relaxed);
    }

    pub fn observe_ios_routing(
        &self,
        notification_tap: u64,
        route_success: u64,
        route_fallback: u64,
    ) {
        if notification_tap > 0 {
            self.notification_tap_total
                .fetch_add(notification_tap, Ordering::Relaxed);
        }
        if route_success > 0 {
            self.route_success_total
                .fetch_add(route_success, Ordering::Relaxed);
        }
        if route_fallback > 0 {
            self.route_fallback_total
                .fetch_add(route_fallback, Ordering::Relaxed);
        }
    }

    pub fn render_prometheus(&self) -> String {
        let snapshot = self.snapshot();
        let mut out = String::new();

        write_counter(
            &mut out,
            "events_bell_total",
            "Total number of bell events ingested by tmuxd.",
            snapshot.events_bell_total,
        );
        write_counter(
            &mut out,
            "events_agent_total",
            "Total number of agent events ingested by tmuxd.",
            snapshot.events_agent_total,
        );
        write_counter(
            &mut out,
            "apns_sent_total",
            "Total number of APNs notifications successfully sent.",
            snapshot.apns_sent_total,
        );
        write_counter(
            &mut out,
            "apns_failed_total",
            "Total number of APNs notification send failures.",
            snapshot.apns_failed_total,
        );
        write_counter(
            &mut out,
            "invalid_token_detected_total",
            "Total number of invalid APNs tokens detected from APNs responses.",
            snapshot.invalid_token_detected_total,
        );
        write_counter(
            &mut out,
            "invalid_token_removed_total",
            "Total number of invalid APNs tokens removed from registry.",
            snapshot.invalid_token_removed_total,
        );
        write_counter(
            &mut out,
            "notification_tap_total",
            "Total number of iOS notification taps.",
            snapshot.notification_tap_total,
        );
        write_counter(
            &mut out,
            "route_success_total",
            "Total number of successful notification routes to pane.",
            snapshot.route_success_total,
        );
        write_counter(
            &mut out,
            "route_fallback_total",
            "Total number of notification routes that fell back to session list.",
            snapshot.route_fallback_total,
        );

        let _ = writeln!(
            out,
            "# HELP event_to_apns_latency_ms Latency from event timestamp to APNs dispatch handling in milliseconds."
        );
        let _ = writeln!(out, "# TYPE event_to_apns_latency_ms histogram");

        for (index, bound) in snapshot
            .event_to_apns_latency_bucket_le_ms
            .iter()
            .enumerate()
        {
            let value = snapshot
                .event_to_apns_latency_bucket_counts
                .get(index)
                .copied()
                .unwrap_or(0);
            let _ = writeln!(
                out,
                "event_to_apns_latency_ms_bucket{{le=\"{}\"}} {}",
                bound, value
            );
        }
        let inf = snapshot
            .event_to_apns_latency_bucket_counts
            .last()
            .copied()
            .unwrap_or(0);
        let _ = writeln!(
            out,
            "event_to_apns_latency_ms_bucket{{le=\"+Inf\"}} {}",
            inf
        );
        let _ = writeln!(
            out,
            "event_to_apns_latency_ms_sum {}",
            snapshot.event_to_apns_latency_ms_total
        );
        let _ = writeln!(
            out,
            "event_to_apns_latency_ms_count {}",
            snapshot.event_to_apns_latency_samples
        );

        out
    }
}

fn write_counter(out: &mut String, name: &str, help: &str, value: u64) {
    let _ = writeln!(out, "# HELP {} {}", name, help);
    let _ = writeln!(out, "# TYPE {} counter", name);
    let _ = writeln!(out, "{} {}", name, value);
}

#[cfg(test)]
mod tests {
    use super::Metrics;

    #[test]
    fn latency_histogram_buckets_and_count_move_together() {
        let metrics = Metrics::default();
        metrics.observe_latency_ms(150);

        let snapshot = metrics.snapshot();
        assert_eq!(snapshot.event_to_apns_latency_samples, 1);
        assert_eq!(snapshot.event_to_apns_latency_ms_total, 150);
        assert_eq!(snapshot.event_to_apns_latency_bucket_counts[0], 0);
        assert_eq!(snapshot.event_to_apns_latency_bucket_counts[1], 1);
        assert_eq!(
            snapshot.event_to_apns_latency_bucket_counts.last().copied(),
            Some(1)
        );
    }

    #[test]
    fn prometheus_output_contains_required_metrics() {
        let metrics = Metrics::default();
        let output = metrics.render_prometheus();

        assert!(output.contains("events_bell_total"));
        assert!(output.contains("events_agent_total"));
        assert!(output.contains("apns_sent_total"));
        assert!(output.contains("apns_failed_total"));
        assert!(output.contains("invalid_token_removed_total"));
        assert!(output.contains("notification_tap_total"));
        assert!(output.contains("route_success_total"));
        assert!(output.contains("route_fallback_total"));
        assert!(output.contains("event_to_apns_latency_ms_bucket"));
    }
}
