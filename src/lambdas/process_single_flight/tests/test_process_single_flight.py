import json
import pytest
from unittest import mock
import requests
from requests.exceptions import ConnectionError, HTTPError

from lambdas.process_single_flight import lambda_function

@pytest.fixture(autouse=True)
def reset_globals():
    lambda_function._index_created = False
    lambda_function._data_view_created = False

@pytest.fixture
def sample_payload():
    return {
      "icao24": "a8b72b",
      "callsign": "SWR100  ",
      "origin_country": "Switzerland",
      "longitude": 8.5393,
      "latitude": 47.4583,
      "baro_altitude_m": 1234.5,
      "on_ground": False,
      "velocity_mps": 100.2,
      "true_track_deg": 45.1,
      "vertical_rate_mps": 0,
      "geo_altitude_m": 1300
    }

@pytest.fixture
def mock_response():
    def _mock_response(status_code, json_data=None, text_data=""):
        m = mock.Mock()
        m.status_code = status_code
        m.text = text_data
        if json_data:
            m.json.return_value = json_data
        
        def raise_for_status():
            if status_code >= 400:
                mock_err_response = mock.Mock()
                mock_err_response.text = text_data
                err = HTTPError()
                err.response = mock_err_response
                raise err
        m.raise_for_status = raise_for_status
        return m
    return _mock_response

@mock.patch('lambdas.process_single_flight.lambda_function.requests')
def test_handler_success_new_index_and_dataview(mock_requests, sample_payload, mock_response):
    mock_requests.exceptions = requests.exceptions
    
    mock_requests.head.return_value = mock_response(404)
    
    mock_requests.put.side_effect = [
        mock_response(200),
        mock_response(201, {"result": "created"})
    ]
    
    mock_requests.get.return_value = mock_response(404)
    mock_requests.post.return_value = mock_response(200)

    result = lambda_function.handler(sample_payload, None)
    
    assert result['statusCode'] == 201
    assert json.loads(result['body'])['result'] == 'created'
    
    es_put_call = mock_requests.put.call_args_list[1]
    es_put_url = es_put_call[0][0]
    es_put_json = es_put_call[1]['json']
    
    assert es_put_url.endswith(f"/_doc/{sample_payload['icao24']}")
    assert es_put_json['location'] == {"lat": 47.4583, "lon": 8.5393} 
    assert 'latitude' not in es_put_json
    
    mock_requests.post.assert_called_once()
    assert mock_requests.put.call_count == 2
    assert lambda_function._index_created is True
    assert lambda_function._data_view_created is True

@mock.patch('lambdas.process_single_flight.lambda_function.requests')
def test_handler_success_existing_index_and_dataview(mock_requests, sample_payload, mock_response):
    mock_requests.exceptions = requests.exceptions

    mock_requests.head.return_value = mock_response(200)
    mock_requests.get.return_value = mock_response(200)
    mock_requests.put.return_value = mock_response(201, {"result": "updated"})

    result = lambda_function.handler(sample_payload, None)

    assert result['statusCode'] == 201
    assert json.loads(result['body'])['result'] == 'updated'
    
    mock_requests.head.assert_called_once()
    mock_requests.get.assert_called_once()
    mock_requests.put.assert_called_once()
    assert lambda_function._index_created is True
    assert lambda_function._data_view_created is True

@mock.patch('lambdas.process_single_flight.lambda_function.requests')
def test_handler_no_icao24(mock_requests, sample_payload):
    mock_requests.exceptions = requests.exceptions

    del sample_payload['icao24']
    result = lambda_function.handler(sample_payload, None)
    
    assert result['statusCode'] == 200
    assert 'Skipped' in result['body']
    mock_requests.put.assert_not_called()

@mock.patch('lambdas.process_single_flight.lambda_function.requests')
def test_handler_es_index_fail(mock_requests, sample_payload, mock_response):
    mock_requests.exceptions = requests.exceptions

    mock_requests.head.return_value = mock_response(200)
    mock_requests.get.return_value = mock_response(200)
    mock_requests.put.return_value = mock_response(500, text_data="Internal Server Error")

    with pytest.raises(Exception) as e:
        lambda_function.handler(sample_payload, None)
    
    assert "HTTP error" in str(e.value)
    assert "Internal Server Error" in str(e.value)

@mock.patch('lambdas.process_single_flight.lambda_function.requests')
def test_handler_es_connection_error(mock_requests, sample_payload):
    mock_requests.exceptions = requests.exceptions
    mock_requests.head.side_effect = requests.exceptions.ConnectionError("Test connection error")

    with pytest.raises(Exception) as e:
        lambda_function.handler(sample_payload, None)
    
    assert "Connection error" in str(e.value)