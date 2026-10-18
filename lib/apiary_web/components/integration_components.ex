defmodule ApiaryWeb.IntegrationComponents do
  # What the pages of Organisation settings › Integrations share: the paths of the
  # section's pages (`paths/2`), the browser title of each page (`page_title/2`) and the
  # integration's mark beside its name (`mark/1`), and the install block, what Install
  # does and Install (`install_block/1`). The section is two LiveViews,
  # `ApiaryWeb.AdapterLive.Index` (the list, and Add an integration) and
  # `ApiaryWeb.AdapterLive.Show` (an integration in the organisation).
  #
  # The mark is a neutral glyph, the same for every integration: never a vendor's logo.
  #
  # The install block says that the integration brings the person back to the
  # organisation's page, that the collections it reaches are listed there, and that the
  # organisation has one installation of it, then offers Install. Install is not yet
  # pressed: it is shown disabled.
  #
  # The feature is hidden from the documentation, so the module is too.
  @moduledoc false
  use ApiaryWeb, :html

  alias Apiary.Accounts.Scope
  alias Apiary.Nodes.Node
  alias Apiary.Organisations.Organisation
  alias ApiaryWeb.SettingsComponents

  @doc false
  # The paths of the section's pages in the scope's organisation: the list, Add an
  # integration, and, given an adapter or its public id, the integration's page.
  @spec paths(Scope.t(), Node.t() | String.t() | nil) :: %{atom => String.t()}
  def paths(%Scope{organisation: organisation}, adapter \\ nil) do
    list = ~p"/#{organisation}/settings/integrations"
    paths = %{list: list, new: list <> "/new"}

    case adapter do
      nil -> paths
      %Node{public_id: public_id} -> Map.put(paths, :show, list <> "/" <> public_id)
      public_id when is_binary(public_id) -> Map.put(paths, :show, list <> "/" <> public_id)
    end
  end

  @doc false
  # The browser title of a page of the section, the most specific first: the page's words
  # (`parts`: the integration's name, a form's act, or none for the list), the section,
  # then the level (`ApiaryWeb.SettingsComponents.page_title/3`).
  @spec page_title(Scope.t(), [String.t()]) :: String.t()
  def page_title(scope, parts),
    do: SettingsComponents.page_title(scope, :organisation, parts ++ [gettext("Integrations")])

  attr :class, :any, default: nil

  @doc false
  # The integration's mark, beside its name; decoration only.
  def mark(assigns) do
    ~H"""
    <.icon name="hero-puzzle-piece-micro" class={["size-4 flex-none text-muted", @class]} />
    """
  end

  attr :id, :string, required: true
  attr :adapter, Node, required: true
  attr :organisation, Organisation, required: true
  attr :collections, :string, required: true, doc: "the word for many of its collections"
  attr :named, :boolean, default: true, doc: "whether the block starts with the name"
  attr :class, :any, default: nil

  @doc false
  # What Install does for `adapter` in `organisation`, then Install.
  def install_block(assigns) do
    ~H"""
    <div
      id={@id}
      class={["max-w-[720px] rounded-box border border-line bg-base-100 px-5 pt-[18px] pb-5", @class]}
    >
      <p :if={@named} id={"#{@id}-name"} class="mb-2.5 flex items-center gap-2.5 font-semibold">
        <.mark /><span class="truncate">{@adapter.name}</span>
      </p>
      <p class="max-w-[68ch] text-[13.5px]/[21px] text-muted">
        {gettext("%{integration} then brings you back here.", integration: @adapter.name)}
        {gettext("The %{collections} it reaches are listed on this page.",
          collections: @collections
        )}
        {gettext("%{organisation} can have one installation of %{integration}.",
          organisation: @organisation.name,
          integration: @adapter.name
        )}
      </p>
      <div class="mt-[18px] flex flex-wrap items-center gap-3">
        <.button id={"#{@id}-install"} variant="primary" type="button" disabled>
          <.icon name="hero-arrow-top-right-on-square-micro" class="size-4" />{gettext("Install")}
        </.button>
      </div>
    </div>
    """
  end
end
