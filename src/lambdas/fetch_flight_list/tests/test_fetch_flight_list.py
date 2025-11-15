import pytest
from unittest.mock import patch, Mock
from lambdas.fetch_flight_list.lambda_function import handler
import requests


MOCK_API_RESPONSE = {
    "time": 1234567890,
    "states": [
        [
            "abc123",
            "TEST123 ",
            "United States",
            None, None,
            -73.78,
            40.64,
            10000.0,
            False,
            250.0,
            90.0,
            5.0,
            None,
            10200.0,
            None,
            None,
            None
        ]
    ]
}


@patch("lambdas.fetch_flight_list.lambda_function.requests.get")
def test_handler_success(mock_get):
    mock_response = Mock()
    mock_response.json.return_value = MOCK_API_RESPONSE
    mock_response.raise_for_status.return_value = None
    mock_get.return_value = mock_response

    event = {}
    context = {}

    result = handler(event, context)
    assert isinstance(result, list)
    assert len(result) == 1
    flight = result[0]
    assert flight["callsign"] == "TEST123"
    assert flight["origin_country"] == "United States"
    assert flight["longitude"] == -73.78
    assert flight["latitude"] == 40.64
    assert flight["baro_altitude_m"] == 10000.0
    assert flight["on_ground"] is False
    assert flight["velocity_mps"] == 250.0
    assert flight["true_track_deg"] == 90.0
    assert flight["vertical_rate_mps"] == 5.0
    assert flight["geo_altitude_m"] == 10200.0


@patch("lambdas.fetch_flight_list.lambda_function.requests.get")
def test_handler_timeout(mock_get):
    mock_get.side_effect = requests.exceptions.Timeout("Request timed out")
    event = {}
    context = {}

    with pytest.raises(Exception) as excinfo:
        handler(event, context)
    assert "Request timed out" in str(excinfo.value)


@patch("lambdas.fetch_flight_list.lambda_function.requests.get")
def test_handler_api_error(mock_get):
    mock_response = Mock()
    mock_response.raise_for_status.side_effect = requests.exceptions.RequestException("API error")
    mock_get.return_value = mock_response
    event = {}
    context = {}

    with pytest.raises(Exception) as excinfo:
        handler(event, context)
    assert "API request failed" in str(excinfo.value)


@patch("lambdas.fetch_flight_list.lambda_function.requests.get")
def test_handler_empty_states(mock_get):
    mock_response = Mock()
    mock_response.json.return_value = {"time": 1234567890, "states": []}
    mock_response.raise_for_status.return_value = None
    mock_get.return_value = mock_response

    event = {}
    context = {}

    result = handler(event, context)
    assert result == []