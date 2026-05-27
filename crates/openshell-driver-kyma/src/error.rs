//! Driver-internal error type and its mapping to `tonic::Status`.
//!
//! RPC handlers throw `DriverError` via `?`; the `From` impl turns each
//! variant into the appropriate gRPC status code. This keeps handlers small
//! and the wire-level error semantics centralized in one place.

use thiserror::Error;

#[derive(Error, Debug)]
pub enum DriverError {
    #[error("invalid argument: {0}")]
    InvalidArgument(String),

    #[error("not found: {0}")]
    NotFound(String),

    #[error("already exists: {0}")]
    AlreadyExists(String),

    #[error("precondition failed: {0}")]
    FailedPrecondition(String),

    #[error("unavailable: {0}")]
    Unavailable(String),

    #[error("kubernetes api: {0}")]
    Kube(#[from] kube::Error),

    #[error(transparent)]
    Internal(#[from] anyhow::Error),
}

impl From<DriverError> for tonic::Status {
    fn from(e: DriverError) -> Self {
        use tonic::{Code, Status};
        match e {
            DriverError::InvalidArgument(m) => Status::new(Code::InvalidArgument, m),
            DriverError::NotFound(m) => Status::new(Code::NotFound, m),
            DriverError::AlreadyExists(m) => Status::new(Code::AlreadyExists, m),
            DriverError::FailedPrecondition(m) => Status::new(Code::FailedPrecondition, m),
            DriverError::Unavailable(m) => Status::new(Code::Unavailable, m),
            DriverError::Kube(kube::Error::Api(s)) if s.code == 404 => {
                Status::new(Code::NotFound, s.message.clone())
            }
            DriverError::Kube(kube::Error::Api(s)) if s.code == 409 => {
                Status::new(Code::AlreadyExists, s.message.clone())
            }
            DriverError::Kube(other) => Status::new(Code::Internal, other.to_string()),
            DriverError::Internal(e) => Status::new(Code::Internal, e.to_string()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tonic::Code;

    fn make_kube_api_status(code: u16, message: &str) -> kube::core::Status {
        kube::core::Status {
            code,
            message: message.to_string(),
            reason: String::new(),
            ..Default::default()
        }
    }

    #[test]
    fn invalid_argument_maps_to_invalid_argument_code() {
        let s: tonic::Status = DriverError::InvalidArgument("missing id".into()).into();
        assert_eq!(s.code(), Code::InvalidArgument);
        assert!(s.message().contains("missing id"));
    }

    #[test]
    fn not_found_maps_to_not_found() {
        let s: tonic::Status = DriverError::NotFound("sb-1".into()).into();
        assert_eq!(s.code(), Code::NotFound);
    }

    #[test]
    fn already_exists_maps_to_already_exists() {
        let s: tonic::Status = DriverError::AlreadyExists("dup".into()).into();
        assert_eq!(s.code(), Code::AlreadyExists);
    }

    #[test]
    fn precondition_maps_to_failed_precondition() {
        let s: tonic::Status = DriverError::FailedPrecondition("no gpu".into()).into();
        assert_eq!(s.code(), Code::FailedPrecondition);
    }

    #[test]
    fn unavailable_maps_to_unavailable() {
        let s: tonic::Status = DriverError::Unavailable("pod not scheduled".into()).into();
        assert_eq!(s.code(), Code::Unavailable);
    }

    #[test]
    fn kube_404_maps_to_not_found() {
        let api_status = make_kube_api_status(404, "not found");
        let s: tonic::Status = DriverError::Kube(kube::Error::Api(Box::new(api_status))).into();
        assert_eq!(s.code(), Code::NotFound);
        assert!(s.message().contains("not found"));
    }

    #[test]
    fn kube_409_maps_to_already_exists() {
        let api_status = make_kube_api_status(409, "already exists");
        let s: tonic::Status = DriverError::Kube(kube::Error::Api(Box::new(api_status))).into();
        assert_eq!(s.code(), Code::AlreadyExists);
    }

    #[test]
    fn kube_500_maps_to_internal() {
        let api_status = make_kube_api_status(500, "server exploded");
        let s: tonic::Status = DriverError::Kube(kube::Error::Api(Box::new(api_status))).into();
        assert_eq!(s.code(), Code::Internal);
    }

    #[test]
    fn internal_anyhow_maps_to_internal() {
        let s: tonic::Status = DriverError::Internal(anyhow::anyhow!("boom")).into();
        assert_eq!(s.code(), Code::Internal);
        assert!(s.message().contains("boom"));
    }
}
