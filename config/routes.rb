FirstApp::Application.routes.draw do
  # Network dashboard — root of the application
  root to: 'network#index'

  # Network-level intelligence views
  scope :network, as: :network do
    get '/',            to: 'network#index',        as: ''
    get 'top_connectors', to: 'network#top_connectors', as: 'top_connectors'
    get 'by_industry',    to: 'network#by_industry',    as: 'by_industry'
  end

  # Business leaders with nested graph-query actions
  resources :business_leaders, only: [:index, :show] do
    member do
      get :network   # extended N-hop reachability
      get :path      # introduction path to a target leader
      get :mutual    # mutual connections with another leader
    end
  end

  # Companies
  resources :companies, only: [:index, :show]
end
