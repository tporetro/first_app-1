class ContactsController < ApplicationController
  before_action :set_contact, only: [:show, :update]

  # GET /contacts?q=...&state=TX&deal_status=in_negotiation
  def index
    @contacts = Contact.includes(:storm_event, :email_outreaches => :email_campaign)
                       .order(last_activity_at: :desc, created_at: :desc)

    @contacts = @contacts.search(params[:q])           if params[:q].present?
    @contacts = @contacts.where(deal_status: params[:deal_status]) if params[:deal_status].present?
    @contacts = @contacts.joins(:storm_event).where(storm_events: { state: params[:state] }) if params[:state].present?

    @contacts = @contacts.limit(200)

    # Summary counts for filter badges
    @status_counts = Contact.group(:deal_status).count
  end

  # GET /contacts/:id
  def show
    @storm       = @contact.storm_event
    @properties  = @storm.properties.where(owner_entity: @contact.owner_entity)
                          .includes(:gamma_report, :email_outreaches => :email_campaign)
    @outreaches  = EmailOutreach.where(property: @properties)
                                .includes(:email_campaign, :gamma_report)
                                .order(created_at: :asc)

    # Build chronological timeline
    @timeline = build_timeline
  end

  # PATCH /contacts/:id
  def update
    attrs = {}
    attrs[:deal_status]      = params[:deal_status]      if params[:deal_status].present?
    attrs[:notes]            = params[:notes]             if params.key?(:notes)
    attrs[:last_activity_at] = Time.now

    if @contact.update(attrs)
      respond_to do |format|
        format.html { redirect_to contact_path(@contact), notice: 'Contact updated.' }
        format.json { render json: { ok: true, deal_status: @contact.deal_status } }
      end
    else
      respond_to do |format|
        format.html { redirect_to contact_path(@contact), alert: @contact.errors.full_messages.join(', ') }
        format.json { render json: { ok: false }, status: :unprocessable_entity }
      end
    end
  end

  private

  def set_contact
    @contact = Contact.find(params[:id])
  end

  def build_timeline
    events = []

    # Storm detection
    events << {
      at:    @storm.created_at,
      type:  :storm,
      icon:  '⛈',
      title: "Storm detected — #{@storm.metro_area}",
      body:  "#{@storm.hail_size}\" hail on #{@storm.event_date.strftime('%B %-d, %Y')} in #{@storm.counties}"
    }

    # Properties identified
    @properties.each do |prop|
      events << {
        at:    prop.created_at,
        type:  :property,
        icon:  '🏢',
        title: "Property identified — #{prop.address}",
        body:  "#{prop.property_type} · #{prop.sq_ft ? number_with_delimiter(prop.sq_ft) + ' sq ft' : 'sq ft unknown'} · #{prop.city}, #{prop.state}"
      }
    end

    # Contact enriched
    events << {
      at:    @contact.created_at,
      type:  :enrichment,
      icon:  '🔍',
      title: "Contact enriched via #{@contact.enrichment_source}",
      body:  [@contact.human_owner_name, @contact.owner_title, @contact.owner_email, @contact.owner_phone].compact.join(' · ')
    }

    # Outreach emails and their events
    @outreaches.each do |outreach|
      label = outreach.followup_day == 0 ? 'Initial outreach' : "Follow-up Day #{outreach.followup_day}"
      events << {
        at:    outreach.sent_at || outreach.created_at,
        type:  :email_sent,
        icon:  '📧',
        title: "#{label} sent",
        body:  outreach.subject
      }

      if (c = outreach.email_campaign)
        if c.delivered_at
          events << { at: c.delivered_at, type: :delivered, icon: '✉️', title: 'Email delivered', body: nil }
        end
        if c.opened_at
          events << { at: c.opened_at, type: :opened, icon: '👁', title: 'Email opened', body: "Variant #{c.variant&.upcase}" }
        end
        if c.clicked_at
          events << { at: c.clicked_at, type: :clicked, icon: '🔗', title: 'Report link clicked', body: nil }
        end
        if c.replied_at
          events << { at: c.replied_at, type: :replied, icon: '⭐', title: 'Reply received', body: nil }
        end
      end

      # Gamma report
      if outreach.gamma_report
        events << {
          at:    outreach.gamma_report.created_at,
          type:  :report,
          icon:  '📊',
          title: 'Gamma report generated',
          body:  outreach.gamma_report.gamma_url
        }
      end
    end

    events.sort_by { |e| e[:at] || Time.now }
  end

  def number_with_delimiter(n)
    n.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse
  end
end
