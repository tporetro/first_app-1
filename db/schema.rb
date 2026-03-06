# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[7.2].define(version: 9) do
  create_table "contacts", force: :cascade do |t|
    t.integer "storm_event_id", null: false
    t.string "owner_entity", null: false
    t.string "human_owner_name"
    t.string "owner_title"
    t.string "owner_email"
    t.string "owner_phone"
    t.string "owner_linkedin"
    t.string "parent_company"
    t.string "org_domain"
    t.string "enrichment_source"
    t.boolean "email_verified", default: false
    t.string "status", default: "pending"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "deal_status", default: "prospecting"
    t.text "notes"
    t.datetime "last_activity_at"
    t.index ["deal_status"], name: "index_contacts_on_deal_status"
    t.index ["owner_email"], name: "index_contacts_on_owner_email"
    t.index ["owner_entity"], name: "index_contacts_on_owner_entity"
    t.index ["storm_event_id"], name: "index_contacts_on_storm_event_id"
  end

  create_table "email_campaigns", force: :cascade do |t|
    t.integer "email_outreach_id", null: false
    t.string "mailgun_message_id"
    t.string "owner_name"
    t.string "address"
    t.string "variant"
    t.datetime "delivered_at"
    t.datetime "opened_at"
    t.datetime "clicked_at"
    t.datetime "replied_at"
    t.string "status", default: "sent"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["email_outreach_id"], name: "index_email_campaigns_on_email_outreach_id"
    t.index ["mailgun_message_id"], name: "index_email_campaigns_on_mailgun_message_id"
    t.index ["status"], name: "index_email_campaigns_on_status"
  end

  create_table "email_outreaches", force: :cascade do |t|
    t.integer "property_id", null: false
    t.integer "contact_id", null: false
    t.integer "gamma_report_id"
    t.string "subject", null: false
    t.text "body", null: false
    t.string "sent_to_email"
    t.string "gmail_message_id"
    t.string "status", default: "draft"
    t.datetime "sent_at"
    t.integer "followup_day", default: 0
    t.text "error_message"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["contact_id"], name: "index_email_outreaches_on_contact_id"
    t.index ["gamma_report_id"], name: "index_email_outreaches_on_gamma_report_id"
    t.index ["property_id"], name: "index_email_outreaches_on_property_id"
    t.index ["sent_at"], name: "index_email_outreaches_on_sent_at"
    t.index ["status"], name: "index_email_outreaches_on_status"
  end

  create_table "gamma_reports", force: :cascade do |t|
    t.integer "property_id", null: false
    t.string "report_id", null: false
    t.string "generation_id"
    t.string "gamma_url"
    t.string "markdown_path"
    t.integer "credits_used"
    t.string "status", default: "pending"
    t.text "error_message"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["generation_id"], name: "index_gamma_reports_on_generation_id"
    t.index ["property_id"], name: "index_gamma_reports_on_property_id"
    t.index ["status"], name: "index_gamma_reports_on_status"
  end

  create_table "properties", force: :cascade do |t|
    t.integer "storm_event_id", null: false
    t.string "property_id"
    t.string "address", null: false
    t.string "city", null: false
    t.string "state", null: false
    t.string "county", null: false
    t.string "property_type"
    t.integer "sq_ft"
    t.string "owner_entity"
    t.string "roof_system"
    t.string "status", default: "identified"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "source"
    t.index ["owner_entity"], name: "index_properties_on_owner_entity"
    t.index ["source"], name: "index_properties_on_source"
    t.index ["status"], name: "index_properties_on_status"
    t.index ["storm_event_id"], name: "index_properties_on_storm_event_id"
  end

  create_table "storm_events", force: :cascade do |t|
    t.string "name", null: false
    t.date "event_date", null: false
    t.decimal "hail_size", precision: 4, scale: 2, null: false
    t.string "counties", null: false
    t.string "state", null: false
    t.string "metro_area"
    t.text "boundary_definition"
    t.string "swath_map_path"
    t.string "status", default: "detected"
    t.text "notes"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["event_date", "state", "metro_area"], name: "index_storm_events_unique_per_day", unique: true
    t.index ["event_date"], name: "index_storm_events_on_event_date"
    t.index ["status"], name: "index_storm_events_on_status"
  end
end
