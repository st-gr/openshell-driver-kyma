//! Map upstream HTTP status → Bedrock-shape error JSON.
//!
//! Claude Code's Bedrock client expects error responses in the form
//! `{"message": "...", "__type": "<ExceptionName>"}`. The mapper bins
//! status codes into the five exception types the prompt specifies.

use http::StatusCode;
use serde::Serialize;

#[derive(Debug, Serialize)]
pub struct BedrockError {
    pub message: String,
    #[serde(rename = "__type")]
    pub r#type: &'static str,
}

impl BedrockError {
    /// Translate an HTTP status code to a Bedrock-shape error JSON.
    /// Caller supplies the message; the type is inferred from status.
    #[must_use]
    pub fn from_status(status: StatusCode, message: impl Into<String>) -> Self {
        let r#type = match status.as_u16() {
            400 => "ValidationException",
            401 | 403 => "AccessDeniedException",
            404 => "ResourceNotFoundException",
            429 => "ThrottlingException",
            500..=599 => "InternalServerException",
            // Anything else (incl. unexpected 2xx coming through error path,
            // 4xx beyond the listed cases) is mapped to the generic 5xx form.
            _ => "InternalServerException",
        };
        Self {
            message: message.into(),
            r#type,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value;

    fn parse_type(err: &BedrockError) -> String {
        let v: Value = serde_json::to_value(err).unwrap();
        v["__type"].as_str().unwrap().to_string()
    }

    #[test]
    fn maps_400_to_validation() {
        let e = BedrockError::from_status(StatusCode::BAD_REQUEST, "bad");
        assert_eq!(parse_type(&e), "ValidationException");
        assert_eq!(e.message, "bad");
    }

    #[test]
    fn maps_401_and_403_to_access_denied() {
        for s in [StatusCode::UNAUTHORIZED, StatusCode::FORBIDDEN] {
            let e = BedrockError::from_status(s, "no");
            assert_eq!(parse_type(&e), "AccessDeniedException", "for {s}");
        }
    }

    #[test]
    fn maps_404_to_resource_not_found() {
        let e = BedrockError::from_status(StatusCode::NOT_FOUND, "x");
        assert_eq!(parse_type(&e), "ResourceNotFoundException");
    }

    #[test]
    fn maps_429_to_throttling() {
        let e = BedrockError::from_status(StatusCode::TOO_MANY_REQUESTS, "slow down");
        assert_eq!(parse_type(&e), "ThrottlingException");
    }

    #[test]
    fn maps_5xx_to_internal_server() {
        for s in [
            StatusCode::INTERNAL_SERVER_ERROR,
            StatusCode::BAD_GATEWAY,
            StatusCode::SERVICE_UNAVAILABLE,
            StatusCode::GATEWAY_TIMEOUT,
        ] {
            let e = BedrockError::from_status(s, "boom");
            assert_eq!(parse_type(&e), "InternalServerException", "for {s}");
        }
    }

    #[test]
    fn maps_unexpected_status_to_internal_server() {
        // 418 is not in the prompt's table; falls through to InternalServerException.
        let e = BedrockError::from_status(StatusCode::IM_A_TEAPOT, "?");
        assert_eq!(parse_type(&e), "InternalServerException");
    }

    #[test]
    fn serializes_with_dunder_type_field() {
        let e = BedrockError::from_status(StatusCode::BAD_REQUEST, "msg");
        let s = serde_json::to_string(&e).unwrap();
        assert!(
            s.contains(r#""__type":"ValidationException""#),
            "actual: {s}"
        );
        assert!(s.contains(r#""message":"msg""#), "actual: {s}");
    }
}
