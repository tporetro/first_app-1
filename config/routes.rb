FirstApp::Application.routes.draw do
  root 'pipeline#index'

  # Pipeline status dashboard
  resources :pipeline, only: [:index, :show] do
    collection { post :trigger }
    resources :reports, only: [:index]
  end

  # Resend email tracking webhooks
  namespace :webhooks do
    post :resend,          to: 'resend#event'
    post 'resend/inbound', to: 'resend#inbound'
  end
end
