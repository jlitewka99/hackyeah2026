defmodule AiControlWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use AiControlWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true
  attr :current_scope, :map, default: nil
  attr :auth, :boolean, default: false
  attr :active_page, :string, default: nil
  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <a href="#main-content" class="skip-link">Skip to content</a>
    <%= if @auth || !@current_scope do %>
      <header class="auth-header">
        <.brand />
        <.theme_toggle id="auth-theme" />
      </header>
      <main id="main-content" class="auth-main">{render_slot(@inner_block)}</main>
    <% else %>
      <div class="app-shell">
        <aside class="sidebar" aria-label="Workspace navigation">
          <div class="px-2 mb-8"><.brand /></div>
          <.workspace_nav
            current_scope={@current_scope}
            active_page={@active_page}
            id="desktop-navigation"
          />
          <div class="mt-auto pt-8 border-t border-[var(--line)]">
            <div class="account-identity px-2 mb-4">
              <p class="font-medium truncate" title={@current_scope.user.email}>
                {@current_scope.user.email}
              </p>
              <p class="muted mt-1">
                {if @current_scope.user.organizer, do: "Organizer", else: "Account"}
              </p>
            </div>
            <div class="flex items-center justify-between gap-2 px-2">
              <.link
                href={~p"/users/log-out"}
                method="delete"
                id="desktop-log-out"
                class="text-link text-sm"
              >Log out</.link>
              <.theme_toggle id="desktop-theme" />
            </div>
          </div>
        </aside>
        <header class="mobile-header">
          <div class="flex items-center justify-between gap-3 mb-4">
            <.brand />
            <.theme_toggle id="mobile-theme" />
          </div>
          <div class="flex items-center justify-between gap-3">
            <details id="mobile-navigation-menu" class="mobile-navigation-menu">
              <summary id="mobile-navigation-toggle" class="button-secondary">
                <span class="truncate">{if @current_scope.organization,
                  do: @current_scope.organization.name,
                  else: "Workspace navigation"}</span>
                <.icon name="hero-chevron-down" class="size-4 shrink-0" />
              </summary>
              <.workspace_nav
                current_scope={@current_scope}
                active_page={@active_page}
                id="mobile-navigation"
              />
            </details>
            <.link
              href={~p"/users/log-out"}
              method="delete"
              id="mobile-log-out"
              class="text-link text-sm shrink-0"
            >Log out</.link>
          </div>
          <p class="account-identity muted mt-3">{@current_scope.user.email}</p>
        </header>
        <main id="main-content" class="app-main">{render_slot(@inner_block)}</main>
      </div>
    <% end %>
    <.flash_group flash={@flash} />
    """
  end

  defp brand(assigns) do
    ~H"""
    <.link href={~p"/"} class="brand" aria-label="AiControl home">
      <span class="brand-symbol"><.icon name="hero-shield-check" class="size-4" /></span>
      <span>AiControl</span>
    </.link>
    """
  end

  attr :current_scope, :map, required: true
  attr :active_page, :string
  attr :id, :string, required: true

  defp workspace_nav(assigns) do
    ~H"""
    <nav id={@id} class="space-y-1">
      <.live_component
        module={AiControlWeb.WorkspaceSwitcherComponent}
        id={"#{@id}-workspace-switcher"}
        current_scope={@current_scope}
      />
      <.link
        :if={@current_scope.organization}
        navigate={~p"/organizations/#{@current_scope.organization.id}"}
        class="nav-link"
        aria-current={@active_page == "overview" && "page"}
      >
        <.icon name="hero-building-office-2" class="size-4 shrink-0" /> Overview
      </.link>
      <.link
        :if={@current_scope.organization && "events.read" in @current_scope.grants.permissions}
        id={"#{@id}-events"}
        navigate={~p"/organizations/#{@current_scope.organization.id}/events"}
        class="nav-link"
        aria-current={@active_page == "events" && "page"}
      ><.icon name="hero-list-bullet" class="size-4 shrink-0" /> Events</.link>
      <.link
        :if={@current_scope.organization && "workflows.read" in @current_scope.grants.permissions}
        id={"#{@id}-runs"}
        navigate={~p"/organizations/#{@current_scope.organization.id}/runs"}
        class="nav-link"
        aria-current={@active_page == "runs" && "page"}
      ><.icon name="hero-arrow-path" class="size-4" /> Workflows</.link>
      <.link
        :if={@current_scope.organization && "budgets.read" in @current_scope.grants.permissions}
        id={"#{@id}-budgets"}
        navigate={~p"/organizations/#{@current_scope.organization.id}/budgets"}
        class="nav-link"
        aria-current={@active_page == "budgets" && "page"}
      ><.icon name="hero-chart-bar" class="size-4 shrink-0" /> Budgets</.link>
      <.link
        :if={@current_scope.organization && "signatures.read" in @current_scope.grants.permissions}
        id={"#{@id}-signatures"}
        navigate={~p"/organizations/#{@current_scope.organization.id}/signatures"}
        class="nav-link"
        aria-current={@active_page == "signatures" && "page"}
      ><.icon name="hero-shield-exclamation" class="size-4 shrink-0" /> Signatures</.link>
      <.link
        :if={@current_scope.organization && "agents.read" in @current_scope.grants.permissions}
        navigate={~p"/organizations/#{@current_scope.organization.id}/agents"}
        class="nav-link"
        aria-current={@active_page == "agents" && "page"}
      >
        <.icon name="hero-cpu-chip" class="size-4 shrink-0" /> Agents
      </.link>
      <.link
        :if={@current_scope.organization && "knowledge.read" in @current_scope.grants.permissions}
        navigate={~p"/organizations/#{@current_scope.organization.id}/knowledge"}
        class="nav-link"
        aria-current={@active_page == "knowledge" && "page"}
        id={"#{@id}-knowledge"}
      >
        <.icon name="hero-book-open" class="size-4 shrink-0" /> Knowledge
      </.link>
      <.link
        :if={@current_scope.organization && "api_keys.read" in @current_scope.grants.permissions}
        navigate={~p"/organizations/#{@current_scope.organization.id}/api-keys"}
        class="nav-link"
        aria-current={@active_page == "api-keys" && "page"}
      >
        <.icon name="hero-key" class="size-4 shrink-0" /> API keys
      </.link>
      <.link
        :if={@current_scope.organization && AiControl.Organizations.managers?(@current_scope)}
        navigate={~p"/organizations/#{@current_scope.organization.id}/members"}
        class="nav-link"
        aria-current={@active_page == "members" && "page"}
      >
        <.icon name="hero-user-group" class="size-4 shrink-0" /> Members
      </.link>
      <.link
        :if={@current_scope.organization && "policies.read" in @current_scope.grants.permissions}
        navigate={~p"/organizations/#{@current_scope.organization.id}/policies"}
        class="nav-link"
        aria-current={@active_page == "policies" && "page"}
      >
        <.icon name="hero-shield-check" class="size-4 shrink-0" /> Policies
      </.link>
      <.link
        :if={@current_scope.user.organizer}
        navigate={~p"/platform/policies"}
        class="nav-link"
        aria-current={@active_page == "global-policy" && "page"}
      >
        <.icon name="hero-shield-check" class="size-4 shrink-0" /> Global policy
      </.link>
      <.link
        :if={@current_scope.user.organizer}
        navigate={~p"/platform/organizations"}
        class="nav-link"
        aria-current={@active_page == "organizations" && "page"}
      >
        <.icon name="hero-building-office-2" class="size-4 shrink-0" /> Organizations
      </.link>
      <.link
        navigate={~p"/users/settings"}
        class="nav-link"
        aria-current={@active_page == "settings" && "page"}
      >
        <.icon name="hero-adjustments-horizontal" class="size-4 shrink-0" /> Account settings
      </.link>
    </nav>
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite" class="flash-stack">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  attr :id, :string, required: true

  def theme_toggle(assigns) do
    ~H"""
    <div id={@id} class="theme-toggle" role="group" aria-label="Appearance">
      <button
        id={"#{@id}-system"}
        type="button"
        class="theme-option"
        data-phx-theme="system"
        phx-click={JS.dispatch("phx:set-theme")}
        aria-label="Use system appearance"
        title="System appearance"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4" />
      </button>
      <button
        id={"#{@id}-light"}
        type="button"
        class="theme-option"
        data-phx-theme="light"
        phx-click={JS.dispatch("phx:set-theme")}
        aria-label="Use light appearance"
        title="Light appearance"
      >
        <.icon name="hero-sun-micro" class="size-4" />
      </button>
      <button
        id={"#{@id}-dark"}
        type="button"
        class="theme-option"
        data-phx-theme="dark"
        phx-click={JS.dispatch("phx:set-theme")}
        aria-label="Use dark appearance"
        title="Dark appearance"
      >
        <.icon name="hero-moon-micro" class="size-4" />
      </button>
    </div>
    """
  end
end
