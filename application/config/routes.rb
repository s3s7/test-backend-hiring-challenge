Rails.application.routes.draw do
  # Health check for uptime monitoring
  get "up" => "rails/health#show", as: :rails_health_check
  root 'posts#index'
  resources :posts do
    collection do
      get :feed
      get :export
    end
    member do
      patch :publish
    end
  end
  resources :comments do
    member do
      patch :approve
    end
  end
  get 'reports/inactive_users', to: 'reports#inactive_users'
  get 'reports/daily_posts', to: 'reports#daily_posts'
  get 'login', to: 'sessions#new'
  post 'login', to: 'sessions#create'
  delete 'logout', to: 'sessions#destroy'
end
