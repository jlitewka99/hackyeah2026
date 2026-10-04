defmodule AiControlWeb.Router do
  use AiControlWeb, :router

  import AiControlWeb.OrganizationAuth
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

  pipeline :agent_api do
    plug AiControlWeb.ApiKeyAuth
  end

  pipeline :chat_api do
    plug :accepts, ["json", "sse"]
  end

  pipeline :agents_read do
    plug :require_permission, "agents.read"
  end

  pipeline :api_keys_read do
    plug :require_permission, "api_keys.read"
  end

  pipeline :policies_read do
    plug :require_permission, "policies.read"
  end

  pipeline :events_read do
    plug :require_permission, "events.read"
  end

  pipeline :workflows_read do
    plug :require_permission, "workflows.read"
  end

  pipeline :budgets_read do
    plug :require_permission, "budgets.read"
  end

  pipeline :knowledge_read do
    plug :require_permission, "knowledge.read"
  end

  pipeline :signatures_read do
    plug :require_permission, "signatures.read"
  end

  scope "/v1", AiControlWeb do
    pipe_through [:api, :agent_api]
    get "/auth", ApiAuthController, :show, log: false
    get "/models", GatewayController, :models, log: false
    post "/tool_calls", ToolController, :create, log: false
    post "/knowledge/search", KnowledgeController, :search, log: false
    get "/memory", KnowledgeController, :index, log: false
    get "/memory/:id", KnowledgeController, :show, log: false
    post "/memory", KnowledgeController, :create, log: false
    patch "/memory/:id", KnowledgeController, :update, log: false
    delete "/memory/:id", KnowledgeController, :delete, log: false
    post "/runs", RunController, :create, log: false
    get "/runs", RunController, :index, log: false
    get "/runs/:id", RunController, :show, log: false
    post "/runs/:id/delegations", RunController, :delegate, log: false
    post "/runs/:id/complete", RunController, :complete, log: false
    post "/runs/:id/stop", RunController, :stop, log: false
  end

  scope "/v1", AiControlWeb do
    pipe_through [:chat_api, :agent_api]
    post "/chat/completions", GatewayController, :chat, log: false
  end

  scope "/", AiControlWeb do
    post "/mcp", MCPController, :create, log: false
  end

  scope "/", AiControlWeb do
    pipe_through :api
    get "/health", HealthController, :health, log: false
    get "/ready", HealthController, :ready, log: false
  end

  scope "/", AiControlWeb do
    pipe_through :browser
    get "/", PageController, :home
    get "/invitations/:token/sign-in", InvitationController, :sign_in, log: false

    live_session :current_user,
      on_mount: [{AiControlWeb.UserAuth, :mount_current_scope}] do
      live "/users/log-in", UserLoginLive, :new
      live "/users/recover", UserRecoveryLive, :new
      live "/users/log-in/:token", UserConfirmationLive, :new, metadata: %{log: false}
      live "/invitations/:token", InvitationLive, :show, metadata: %{log: false}
    end

    post "/users/log-in", UserSessionController, :create
    post "/users/recover", UserSessionController, :request_link
    delete "/users/log-out", UserSessionController, :delete
    post "/invitations/accept", InvitationController, :accept, log: false
  end

  scope "/", AiControlWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :authenticated,
      on_mount: [
        {AiControlWeb.UserAuth, :require_authenticated},
        {AiControlWeb.WorkspaceNavigation, :default}
      ] do
      live "/users/settings", UserSettingsLive, :edit
      live "/organizations", OrganizationsLive, :index

      live "/users/settings/confirm-email/:token", UserSettingsLive, :confirm_email,
        metadata: %{log: false}
    end

    post "/users/update-password", UserSessionController, :update_password
  end

  scope "/organizations/:organization_id", AiControlWeb do
    pipe_through [:browser, :require_authenticated_user, :require_organization, :knowledge_read]
    get "/knowledge/resources", KnowledgeController, :index, log: false
    get "/knowledge/resources/:id", KnowledgeController, :show, log: false
    post "/knowledge/resources", KnowledgeController, :create, log: false
    patch "/knowledge/resources/:id", KnowledgeController, :update, log: false
    delete "/knowledge/resources/:id", KnowledgeController, :delete, log: false

    live_session :knowledge,
      on_mount: [
        {AiControlWeb.OrganizationAuth, :require_organization},
        {AiControlWeb.WorkspaceNavigation, :default}
      ] do
      live "/knowledge", OrganizationKnowledgeLive, :index
      live "/knowledge/new", OrganizationKnowledgeLive, :new
      live "/knowledge/:resource_id", OrganizationKnowledgeLive, :show
      live "/knowledge/:resource_id/edit", OrganizationKnowledgeLive, :edit
    end
  end

  scope "/organizations/:organization_id", AiControlWeb do
    pipe_through [:browser, :require_authenticated_user, :require_organization, :workflows_read]

    live_session :workflows,
      on_mount: [
        {AiControlWeb.OrganizationAuth, :require_organization},
        {AiControlWeb.WorkspaceNavigation, :default}
      ] do
      live "/runs", OrganizationRunsLive, :index
      live "/runs/:run_id", OrganizationRunLive, :show
    end
  end

  scope "/organizations/:organization_id", AiControlWeb do
    pipe_through [:browser, :require_authenticated_user, :require_organization, :events_read]
    get "/events/export", EventExportController, :index, log: false

    live_session :events,
      on_mount: [
        {AiControlWeb.OrganizationAuth, :require_organization},
        {AiControlWeb.WorkspaceNavigation, :default}
      ] do
      live "/events", OrganizationEventsLive, :index
      live "/events/:event_id", OrganizationEventLive, :show
    end
  end

  scope "/organizations/:organization_id", AiControlWeb do
    pipe_through [:browser, :require_authenticated_user, :require_organization, :budgets_read]

    live_session :budgets,
      on_mount: [
        {AiControlWeb.OrganizationAuth, :require_organization},
        {AiControlWeb.WorkspaceNavigation, :default}
      ] do
      live "/budgets", OrganizationBudgetsLive, :index
    end
  end

  scope "/organizations/:organization_id", AiControlWeb do
    pipe_through [:browser, :require_authenticated_user, :require_organization, :signatures_read]

    live_session :signatures,
      on_mount: [
        {AiControlWeb.OrganizationAuth, :require_organization},
        {AiControlWeb.WorkspaceNavigation, :default}
      ] do
      live "/signatures", OrganizationSignaturesLive, :index
    end
  end

  scope "/organizations/:organization_id", AiControlWeb do
    pipe_through [:browser, :require_authenticated_user, :require_organization]

    live_session :organization,
      on_mount: [
        {AiControlWeb.OrganizationAuth, :require_organization},
        {AiControlWeb.WorkspaceNavigation, :default}
      ] do
      live "/", OrganizationOverviewLive, :show
    end
  end

  scope "/organizations/:organization_id", AiControlWeb do
    pipe_through [:browser, :require_authenticated_user, :require_organization, :agents_read]

    live_session :agents,
      on_mount: [
        {AiControlWeb.OrganizationAuth, :require_organization},
        {AiControlWeb.WorkspaceNavigation, :default}
      ] do
      live "/agents", OrganizationAgentsLive, :index
    end
  end

  scope "/organizations/:organization_id", AiControlWeb do
    pipe_through [:browser, :require_authenticated_user, :require_organization, :api_keys_read]

    live_session :api_keys,
      on_mount: [
        {AiControlWeb.OrganizationAuth, :require_organization},
        {AiControlWeb.WorkspaceNavigation, :default}
      ] do
      live "/api-keys", OrganizationApiKeysLive, :index
    end
  end

  scope "/organizations/:organization_id", AiControlWeb do
    pipe_through [:browser, :require_authenticated_user, :require_organization, :require_manager]

    live_session :organization_management,
      on_mount: [
        {AiControlWeb.OrganizationAuth, :require_organization},
        {AiControlWeb.WorkspaceNavigation, :default}
      ] do
      live "/members", OrganizationMembersLive, :index
      live "/members/:membership_id/access", OrganizationMemberAccessLive, :edit
    end
  end

  scope "/organizations/:organization_id", AiControlWeb do
    pipe_through [:browser, :require_authenticated_user, :require_organization, :policies_read]
    get "/policies/versions/:version_id/export", PolicyExportController, :organization

    live_session :policies,
      on_mount: [
        {AiControlWeb.OrganizationAuth, :require_organization},
        {AiControlWeb.WorkspaceNavigation, :default}
      ] do
      live "/policies", OrganizationPoliciesLive, :index
    end
  end

  scope "/platform", AiControlWeb do
    pipe_through [:browser, :require_authenticated_user, :require_organizer]
    get "/policies/versions/:version_id/export", PolicyExportController, :platform

    live_session :organizer,
      on_mount: [
        {AiControlWeb.UserAuth, :require_organizer},
        {AiControlWeb.WorkspaceNavigation, :default}
      ] do
      live "/organizations", PlatformOrganizationsLive, :index
      live "/policies", PlatformPoliciesLive, :index
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
