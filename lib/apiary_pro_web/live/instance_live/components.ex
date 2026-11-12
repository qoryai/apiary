defmodule ApiaryProWeb.InstanceLive.Components do
  @moduledoc """
  What Instance settings' pages share: its two sections, Organisations
  (`ApiaryProWeb.InstanceLive.Organisations`) and Accounts
  (`ApiaryProWeb.InstanceLive.Accounts`), which the console lists as the second column of
  the Instance level (`c:ApiaryWeb.Edition.instance_sections/1`, `ApiaryProWeb.Edition`),
  and the scope the pages ask the instance's data in.

  An Instance page is under `/instance`, with no organisation in its path: the person's
  scope there is the one they came from (`ApiaryWeb.Routes.instance_routes/1`). The pages
  ask the instance's data and its actions in the instance organisation, whose owners, the
  instance admins, they are for: the scope of `Apiary.Access.instance_scope/1`
  (`instance_scope/1`). `on_mount/4` assigns that scope as `:scope`, and for anyone else
  the page is not found.
  """
  use Gettext, backend: ApiaryProWeb.Gettext

  alias Apiary.Access
  alias Apiary.Accounts.Scope
  alias ApiaryProWeb.InstanceLive.Paths
  alias ApiaryWeb.Nav.Entry

  @doc """
  instance_scope/1 is `Apiary.Access.instance_scope/1`, the person of `scope` in the
  instance organisation: `{:ok, scope}` for an instance admin, who may read the instance
  (`instance.read`); `:error` for anyone else, and before the instance's first sign-up.
  `can?/3` runs no SELECT for an instance action of this scope on an organisation with its
  tenant in `edition` (`Apiary.Access.in_instance/1`).
  """
  @spec instance_scope(Scope.t() | nil) :: {:ok, Scope.t()} | :error
  def instance_scope(scope), do: Access.instance_scope(scope)

  @doc """
  on_mount/4 puts the instance scope (`instance_scope/1`) into the socket as `:scope`, or
  answers not found.
  """
  def on_mount(:instance, _params, _session, socket) do
    case instance_scope(socket.assigns.current_scope) do
      {:ok, scope} -> {:cont, Phoenix.Component.assign(socket, :scope, scope)}
      :error -> raise ApiaryWeb.NotFound
    end
  end

  @doc """
  sections/1 is Instance settings' sections the person of `scope` may open, in order, as
  `ApiaryWeb.Nav.Entry` values of the Instance level: Organisations and Accounts, both the
  instance admins'; none for anyone else.
  """
  @spec sections(Scope.t() | nil) :: [Entry.t()]
  def sections(scope) do
    case instance_scope(scope) do
      {:ok, _scope} ->
        [
          %Entry{
            section: :instance,
            key: :organisations,
            label: gettext("Organisations"),
            icon: "hero-building-office-2",
            path: Paths.organisations(),
            place: :instance
          },
          %Entry{
            section: :instance,
            key: :accounts,
            label: gettext("Accounts"),
            icon: "hero-users",
            path: Paths.accounts(),
            place: :instance
          }
        ]

      :error ->
        []
    end
  end
end
