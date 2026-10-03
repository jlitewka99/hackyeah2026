defmodule AiControlWeb.Router do
  use AiControlWeb, :router

  import AiControlWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {AiControlWeb.Layouts, :root}
    plug :protect_from_forgery

    plug :put_secure_browser_headers, %{
      "content-security-policy" => "base-uri 'self'; frame-ancestors 'self';"
    }

    plug :fetch_current_scope_for_user
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", AiControlWeb do
    pipe_through :browser
    get "/", PageController, :home

    live_session :current_user,
      on_mount: [{AiControlWeb.UserAuth, :mount_current_scope}] do
      live "/users/log-in", UserLoginLive, :new
      live "/users/recover", UserRecoveryLive, :new
      live "/users/log-in/:token", UserConfirmationLive, :new, metadata: %{log: false}
    end

    post "/users/log-in", UserSessionController, :create
    post "/users/recover", UserSessionController, :request_link
    delete "/users/log-out", UserSessionController, :delete
  end

  scope "/", AiControlWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :authenticated,
      on_mount: [{AiControlWeb.UserAuth, :require_authenticated}] do
      live "/users/settings", UserSettingsLive, :edit

      live "/users/settings/confirm-email/:token", UserSettingsLive, :confirm_email,
        metadata: %{log: false}
    end

    post "/users/update-password", UserSessionController, :update_password
  end

  scope "/platform", AiControlWeb do
    pipe_through [:browser, :require_authenticated_user, :require_organizer]

    live_session :organizer,
      on_mount: [{AiControlWeb.UserAuth, :require_organizer}] do
      live "/organizations", PlatformOrganizationsLive, :index
    end
  end

  if Application.compile_env(:ai_control, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through [:browser, :require_authenticated_user, :require_organizer]

      live_dashboard "/dashboard",
        metrics: AiControlWeb.Telemetry,
        on_mount: [{AiControlWeb.UserAuth, :require_organizer}]

      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
