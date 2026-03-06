require 'test_helper'
require 'minitest/mock'

class PropStreamServiceTest < ActiveSupport::TestCase
  # Freeze auth so tests don't actually hit PropStream
  AUTH_RESPONSE = { 'accessToken' => 'tok_test_123' }.freeze

  PROPERTY_RESPONSE = {
    'properties' => [{
      'id'         => 'ps_001',
      'ownerName'  => 'ACME ROOFING LLC',
      'address'    => { 'street' => '123 Main St', 'city' => 'Dallas', 'state' => 'TX', 'zip' => '75201' },
      'ownerMailingAddress' => { 'street' => '456 Owner Way', 'city' => 'Plano', 'state' => 'TX', 'zip' => '75023' },
      'yearBuilt'  => 1998,
      'sqft'       => 3200,
      'estimatedValue' => 485_000,
      'equityPercent'  => 62
    }]
  }.freeze

  PROPERTY_INDIVIDUAL = PROPERTY_RESPONSE.deep_dup.tap do |r|
    r['properties'][0]['ownerName'] = 'John Doe'
  end.freeze

  SKIP_TRACE_RESPONSE = {
    'results' => [{
      'contacts' => [{ 'email' => 'john@acmeroofing.com', 'phone' => '972-555-0101' }]
    }]
  }.freeze

  setup do
    # Reset cached auth token before each test
    PropStreamService.instance_variable_set(:@token, nil)
    PropStreamService.instance_variable_set(:@token_fetched, nil)
    # Provide env vars
    ENV['PROPSTREAM_USERNAME'] = 'test@example.com'
    ENV['PROPSTREAM_PASSWORD'] = 'secret'
  end

  teardown do
    ENV.delete('PROPSTREAM_USERNAME')
    ENV.delete('PROPSTREAM_PASSWORD')
    ENV.delete('PROPSTREAM_SKIP_TRACE')
    PropStreamService.instance_variable_set(:@token, nil)
    PropStreamService.instance_variable_set(:@token_fetched, nil)
  end

  # --- auth ---
  test 'returns nil and logs warning when credentials are missing' do
    ENV.delete('PROPSTREAM_USERNAME')
    result = PropStreamService.lookup(address: '123 Main St', state: 'TX')
    assert_nil result
  end

  test 'caches auth token between calls' do
    login_call_count = 0

    PropStreamService.stub(:post_json, ->(path, _body, token:) {
      if path == '/login'
        login_call_count += 1
        AUTH_RESPONSE
      else
        PROPERTY_RESPONSE
      end
    }) do
      PropStreamService.stub(:get_json, ->(*) { PROPERTY_RESPONSE }) do
        PropStreamService.lookup(address: '123 Main St', state: 'TX')
        PropStreamService.lookup(address: '123 Main St', state: 'TX')
      end
    end

    assert_equal 1, login_call_count, 'Token should be cached; login called more than once'
  end

  # --- property lookup ---
  test 'returns nil when no properties found' do
    PropStreamService.stub(:post_json, ->(*) { AUTH_RESPONSE }) do
      PropStreamService.stub(:get_json, ->(*) { { 'properties' => [] } }) do
        result = PropStreamService.lookup(address: '999 Nowhere St', state: 'TX')
        assert_nil result
      end
    end
  end

  test 'returns owner name from property record' do
    PropStreamService.stub(:post_json, ->(*) { AUTH_RESPONSE }) do
      PropStreamService.stub(:get_json, ->(*) { PROPERTY_RESPONSE }) do
        result = PropStreamService.lookup(address: '123 Main St', city: 'Dallas', state: 'TX', zip: '75201')
        assert_equal 'ACME ROOFING LLC', result.owner_name
      end
    end
  end

  test 'detects LLC as non-individual owner' do
    PropStreamService.stub(:post_json, ->(*) { AUTH_RESPONSE }) do
      PropStreamService.stub(:get_json, ->(*) { PROPERTY_RESPONSE }) do
        result = PropStreamService.lookup(address: '123 Main St', state: 'TX')
        assert_equal false, result.owner_is_individual
      end
    end
  end

  test 'detects person name as individual owner' do
    PropStreamService.stub(:post_json, ->(*) { AUTH_RESPONSE }) do
      PropStreamService.stub(:get_json, ->(*) { PROPERTY_INDIVIDUAL }) do
        result = PropStreamService.lookup(address: '123 Main St', state: 'TX')
        assert_equal true, result.owner_is_individual
      end
    end
  end

  test 'returns property characteristics' do
    PropStreamService.stub(:post_json, ->(*) { AUTH_RESPONSE }) do
      PropStreamService.stub(:get_json, ->(*) { PROPERTY_RESPONSE }) do
        result = PropStreamService.lookup(address: '123 Main St', state: 'TX')
        assert_equal 1998,    result.year_built
        assert_equal 3200,    result.sqft
        assert_equal 485_000, result.estimated_value
        assert_equal 62,      result.equity_percent
      end
    end
  end

  # --- skip trace ---
  test 'does not skip trace when PROPSTREAM_SKIP_TRACE env var is not set' do
    skip_trace_called = false

    PropStreamService.stub(:post_json, ->(path, _body, token:) {
      skip_trace_called = true if path.include?('skip-trace')
      path == '/login' ? AUTH_RESPONSE : SKIP_TRACE_RESPONSE
    }) do
      PropStreamService.stub(:get_json, ->(*) { PROPERTY_RESPONSE }) do
        PropStreamService.lookup(address: '123 Main St', state: 'TX', skip_trace: true)
      end
    end

    assert_not skip_trace_called, 'Skip trace should only run when PROPSTREAM_SKIP_TRACE=true'
  end

  test 'skip traces when env var is set and returns phone and email' do
    ENV['PROPSTREAM_SKIP_TRACE'] = 'true'

    PropStreamService.stub(:post_json, ->(path, _body, token:) {
      path == '/login' ? AUTH_RESPONSE : SKIP_TRACE_RESPONSE
    }) do
      PropStreamService.stub(:get_json, ->(*) { PROPERTY_RESPONSE }) do
        result = PropStreamService.lookup(address: '123 Main St', state: 'TX', skip_trace: true)
        assert_equal 'john@acmeroofing.com', result.owner_email
        assert_equal '972-555-0101',         result.owner_phone
      end
    end
  end

  # --- SmartEnrichmentService integration ---
  test 'propstream runs as step 0 in smart enrichment' do
    ps_result = PropStreamService::Result.new(
      owner_name:            'Acme Roofing LLC',
      owner_phone:           '214-555-0199',
      owner_email:           nil,
      owner_is_individual:   false,
      owner_mailing_address: '456 Owner Way, Plano, TX 75023'
    )

    PropStreamService.stub(:lookup, ->(**) { ps_result }) do
      SmartEnrichmentService.stub(:claude_web_enrich, ->(**) { nil }) do
        ClayEnrichmentService.stub(:enrich, ->(**) { nil }) do
          result = SmartEnrichmentService.enrich(
            owner_entity: 'Acme Roofing LLC',
            address:      '123 Main St, Dallas, TX 75201',
            state:        'TX'
          )
          assert_includes result.enrichment_source, 'propstream'
          assert_equal '214-555-0199', result.owner_phone
        end
      end
    end
  end

  test 'smart enrichment skips propstream when no address provided' do
    ps_called = false

    PropStreamService.stub(:lookup, ->(**) { ps_called = true; nil }) do
      SmartEnrichmentService.stub(:claude_web_enrich, ->(**) { nil }) do
        ClayEnrichmentService.stub(:enrich, ->(**) { nil }) do
          SmartEnrichmentService.enrich(owner_entity: 'Acme Roofing LLC', state: 'TX')
        end
      end
    end

    assert_not ps_called, 'PropStream should not be called when no address is available'
  end
end
