defmodule ApiaryProWeb.InstanceLive.Components do
  @moduledoc """
  What Instance settings' pages share: its two sections, Organisations
  (`ApiaryProWeb.InstanceLive.Organisations`) and Accounts
  (`ApiaryProWeb.InstanceLive.Accounts`), which the console lists as the second column of
  the Instance level (`c:ApiaryWeb.Edition.instance_sections/1`, `ApiaryProWeb.Edition`).

  An Instance page is under `/instance`, with no organisation in its path: the person's
  scope there is the one they came from (`ApiaryWeb.Routes.instance_routes/1`). The pages
  read the instance's data and check its actions in the instance organisation, whose
  owners, the instance admins, they are for: the scope of
  `Apiary.Access.instance_scope/1`. Each page mounts on the core's
  `ApiaryWeb.Access.on_mount/4` with `:instance`, which assigns that scope as `:scope`,
  and for anyone else the page is not found.
  """
  use Gettext, backend: ApiaryProWeb.Gettext

  alias Apiary.Access
  alias Apiary.Accounts.Scope
  alias ApiaryProWeb.InstanceLive.Paths
  alias ApiaryWeb.Nav.Entry

  @doc """
  sections/1 is Instance settings' sections the person of `scope` may open, in order, as
  `ApiaryWeb.Nav.Entry` values of the Instance level: Organisations and Accounts, both the
  instance admins'; none for anyone else.
  """
  @spec sections(Scope.t() | nil) :: [Entry.t()]
  def sections(scope) do
    case Access.instance_scope(scope) do
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
