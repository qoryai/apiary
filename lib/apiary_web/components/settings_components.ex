defmodule ApiaryWeb.SettingsComponents do
  @moduledoc """
  The tabs of the organisation's settings: the core's own, the settings page
  (`ApiaryWeb.SettingsLive`), and after it the tabs an edition adds
  (`c:ApiaryWeb.Edition.settings_tabs/1`), each a page of the edition's own. There are no
  tabs while the edition adds none: the settings are one page.

  A page of the settings reads its tabs when it mounts, and again when the reader's
  membership changes (`list_tabs/1`), since an edition's tab may ask the database whether it
  has anything for the reader; it renders them with `settings_tabs/1`, its own marked
  current.
  """
  use ApiaryWeb, :html

  alias Apiary.Accounts.Scope
  alias ApiaryWeb.Nav.Entry

  @doc """
  list_tabs/1 is the tabs of the organisation's settings for the reader of `scope`: the
  core's own, then the edition's; none when the edition adds none.
  """
  @spec list_tabs(Scope.t()) :: [Entry.t()]
  def list_tabs(scope) do
    case ApiaryWeb.Edition.settings_tabs(scope) do
      [] -> []
      tabs -> [own_tab() | tabs]
    end
  end

  defp own_tab do
    %Entry{
      key: :organisation,
      label: gettext("General"),
      icon: "hero-building-office-2-micro",
      path: fn organisation, _workspace -> ~p"/#{organisation}/settings" end,
      place: :organisation
    }
  end

  @doc """
  settings_tabs/1 renders the tabs of the organisation's settings (`list_tabs/1`), `current`
  marked as the page the reader is on; nothing when there are none.
  """
  attr :tabs, :list, required: true, doc: "the tabs, as `list_tabs/1` gives them"
  attr :current, :atom, required: true, doc: "the key of the tab of the page"
  attr :organisation, :any, required: true

  @spec settings_tabs(map) :: Phoenix.LiveView.Rendered.t()
  def settings_tabs(assigns) do
    ~H"""
    <.tabs :if={@tabs != []} id="settings-tabs" label={gettext("Settings")}>
      <:tab
        :for={tab <- @tabs}
        id={"settings-tab-#{tab.key}"}
        navigate={Entry.path(tab, @organisation, nil)}
        icon={tab.icon}
        current={tab.key == @current}
      >
        {tab.label}
      </:tab>
    </.tabs>
    """
  end
end
