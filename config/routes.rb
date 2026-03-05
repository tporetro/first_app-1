FirstApp::Application.routes.draw do
  # Render health check
  get '/up', to: proc { [200, {}, ['OK']] }

  root 'pipeline#index'
  get '/admin/seed_demo', to: 'admin#seed_demo'

  # Pipeline status dashboard
  resources :pipeline, only: [:index, :show] do
    collection { post :trigger }
    resources :reports, only: [:index]
  end

  # CRM — contacts search, timeline, notes
  resources :contacts, only: [:index, :show, :update]

  # Resend email tracking webhooks
  namespace :webhooks do
    post :resend,          to: 'resend#event'
    post 'resend/inbound', to: 'resend#inbound'
  end
end
