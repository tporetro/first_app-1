require 'test_helper'
require 'minitest/mock'

class SmartEnrichmentServiceTest < ActiveSupport::TestCase
  # Stubs out external API calls so no real network traffic is made.

  WEB_RESULT = {
    human_owner_name: 'Jane Smith',
    owner_title:      'Managing Member',
    owner_email:      nil,
    owner_phone:      nil,
    owner_linkedin:   'https://linkedin.com/in/janesmith',
    parent_company:   nil,
    org_domain:       'acmeroofing.com'
  }.freeze

  CLAY_RESULT = {
    human_owner_name: nil,
    owner_title:      nil,
    owner_email:      'jane@acmeroofing.com',
    owner_phone:      '214-555-0100',
    owner_linkedin:   nil,
    parent_company:   nil,
    org_domain:       'acmeroofing.com'
  }.freeze

  # --- order: web search runs before Clay ---
  test 'web search runs before clay' do
    call_order = []

    SmartEnrichmentService.stub(:claude_web_enrich, ->(**) { call_order << :web; WEB_RESULT }) do
      ClayEnrichmentService.stub(:enrich, ->(**) { call_order << :clay; CLAY_RESULT }) do
        SmartEnrichmentService.enrich(owner_entity: 'Acme Roofing LLC', state: 'TX')
      end
    end

    assert_equal [:web, :clay], call_order, 'Expected web search to run before Clay'
  end

  # --- domain found by web search is passed to Clay ---
  test 'domain from web search is passed to clay' do
    received_domain = nil

    SmartEnrichmentService.stub(:claude_web_enrich, ->(**) { WEB_RESULT }) do
      clay_spy = ->(owner_entity:, address: nil, state: nil, domain: nil) {
        received_domain = domain
        CLAY_RESULT
      }
      ClayEnrichmentService.stub(:enrich, clay_spy) do
        SmartEnrichmentService.enrich(owner_entity: 'Acme Roofing LLC', state: 'TX')
      end
    end

    assert_equal 'acmeroofing.com', received_domain, 'Expected web-found domain to be forwarded to Clay'
  end

  # --- results are merged correctly (web fills name/domain, clay fills email/phone) ---
  test 'web and clay results are merged' do
    SmartEnrichmentService.stub(:claude_web_enrich, ->(**) { WEB_RESULT }) do
      ClayEnrichmentService.stub(:enrich, ->(**) { CLAY_RESULT }) do
        result = SmartEnrichmentService.enrich(owner_entity: 'Acme Roofing LLC', state: 'TX')

        assert_equal 'Jane Smith',            result.human_owner_name
        assert_equal 'jane@acmeroofing.com',  result.owner_email
        assert_equal '214-555-0100',          result.owner_phone
        assert_equal 'acmeroofing.com',       result.org_domain
        assert_includes result.enrichment_source, 'web_search'
        assert_includes result.enrichment_source, 'clay'
      end
    end
  end

  # --- web search data is not overwritten by Clay ---
  test 'clay does not overwrite web search data' do
    clay_with_different_name = CLAY_RESULT.merge(human_owner_name: 'Someone Else')

    SmartEnrichmentService.stub(:claude_web_enrich, ->(**) { WEB_RESULT }) do
      ClayEnrichmentService.stub(:enrich, ->(**) { clay_with_different_name }) do
        result = SmartEnrichmentService.enrich(owner_entity: 'Acme Roofing LLC', state: 'TX')
        assert_equal 'Jane Smith', result.human_owner_name, 'Web search name should not be overwritten by Clay'
      end
    end
  end

  # --- graceful when web search returns nil ---
  test 'falls through to clay if web search returns nil' do
    SmartEnrichmentService.stub(:claude_web_enrich, ->(**) { nil }) do
      ClayEnrichmentService.stub(:enrich, ->(**) { CLAY_RESULT }) do
        result = SmartEnrichmentService.enrich(owner_entity: 'Acme Roofing LLC', state: 'TX')
        assert_equal 'jane@acmeroofing.com', result.owner_email
        assert_equal 'clay', result.enrichment_source
      end
    end
  end

  # --- Clay skips company enrichment when domain already known ---
  test 'clay skips company enrichment when domain is supplied' do
    company_enrich_called = false

    SmartEnrichmentService.stub(:claude_web_enrich, ->(**) { WEB_RESULT }) do
      ClayEnrichmentService.stub(:enrich_company, ->(**) { company_enrich_called = true; {} }) do
        ClayEnrichmentService.stub(:enrich_person, ->(**) { {} }) do
          ClayEnrichmentService.enrich(
            owner_entity: 'Acme Roofing LLC',
            domain:       'acmeroofing.com'
          )
        end
      end
    end

    assert_not company_enrich_called, 'Clay should skip company enrichment when domain is already known'
  end
end
