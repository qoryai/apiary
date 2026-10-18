defmodule ApiaryWeb.AdapterSetupController do
  # Set up: `POST /instance/adapters/:adapter_id/setup`, where an instance admin starts
  # the set-up of an adapter, named by its public id (`na_…`), at the system it reads
  # from. Not a page: the form that posts here is Set up's, on the adapter's Overview and
  # on its row of Instance settings › Adapters, with the session's CSRF token, which the
  # `:browser` pipeline checks first.
  #
  # In order:
  #
  #   1. anyone but an instance admin (`Apiary.Adapters.authorize_instance/2`) is answered
  #      as a path that does not exist, as on the Instance's pages, before anything is
  #      looked up; so is an adapter the instance admin does not find (deleted, of
  #      another kind, or none);
  #   2. `Apiary.Adapters.setup/2` makes a new setup pass, and the instance admin is sent
  #      to the address it answers, the adapter's `setup_url` with the pass, by a page
  #      that refreshes to it (`ApiaryWeb.SendOn`), told no referrer and kept by no cache;
  #   3. while the adapter declares no `setup_url`, holds no key in use, or is installed
  #      with Qory Apiary and no longer listed (turned off there), nothing changes, and
  #      the instance admin is sent back, to the Overview, or to the list when the form
  #      says it was there (`back`, `list`), with why: nothing to set up, the last case
  #      too.
  #
  # The pass is in the answer's body alone: never in a path, a parameter, a header or a
  # log line.
  #
  # The feature is hidden from the documentation, so the module is too.
  @moduledoc false

  use ApiaryWeb, :controller
  use ApiaryWeb.Features, instance: :factory

  alias Apiary.Adapters
  alias Apiary.Nodes.Node
  alias ApiaryWeb.{AdapterComponents, SendOn}

  def create(conn, %{"adapter_id" => adapter_id} = params) do
    scope = conn.assigns.current_scope

    with :ok <- Adapters.authorize_instance(scope),
         %Node{} = adapter <- Adapters.get_adapter(scope, adapter_id) || {:error, :not_found},
         {:ok, url} <- Adapters.setup(scope, adapter) do
      SendOn.send_on(conn, url)
    else
      {:error, reason} when reason in [:forbidden, :not_found] ->
        raise ApiaryWeb.NotFound

      # No pass could be made (`:invalid`), or its entry was not recorded (a changeset):
      # nothing changed, and nothing is set up now.
      {:error, reason} when reason in [:no_setup_url, :unlisted, :invalid] ->
        back(conn, params, gettext("This adapter has nothing to set up now."))

      {:error, %Ecto.Changeset{}} ->
        back(conn, params, gettext("This adapter has nothing to set up now."))

      {:error, :no_key} ->
        back(conn, params, gettext("The adapter needs a key in use before it can be set up."))
    end
  end

  # Back where the form was, with why nothing happened.
  defp back(conn, %{"adapter_id" => adapter_id} = params, message) do
    paths = AdapterComponents.paths(adapter_id)
    to = if params["back"] == "list", do: paths.list, else: paths.overview

    conn
    |> put_flash(:error, message)
    |> redirect(to: to)
  end
end
