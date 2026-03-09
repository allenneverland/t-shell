use std::sync::Arc;

use crate::apns::ApnsService;
use crate::config::Config;
use crate::db::Database;
use crate::metrics::Metrics;

#[derive(Clone)]
pub struct AppState {
    pub config: Arc<Config>,
    pub db: Arc<Database>,
    pub apns: Option<Arc<ApnsService>>,
    pub metrics: Arc<Metrics>,
}
