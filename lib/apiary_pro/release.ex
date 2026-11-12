defmodule ApiaryPro.Release do
  @moduledoc """
  The edition's release commands, run as the core's are (`Apiary.Release.run/1`):
  `bin/apiary eval "ApiaryPro.Release.…"`. Whoever can run a command controls the instance
  already, so a command asks nobody's role; what it changes is recorded in the trail of
  the organisation it changes, by the instance, and names the instance admin who asked
  where there is one.
  """

  alias Apiary.Organisations.Organisation
  alias Apiary.Release

  @doc """
  Purges an organisation at once, by its slug or its id, for an erasure request the
  instance received in writing, and says who asked, by the email address of an instance
  admin's account, an owner of the instance organisation:
  `bin/apiary eval 'ApiaryPro.Release.purge_now("acme", "admin@qory.example")'`. The
  organisation is marked for deletion if it is not yet, its grace period ends now, and
  every row it holds is deleted, its workspaces and its audit trail among them; the
  instance keeps one line of it, with who asked and the trigger `erasure_request`
  (`Apiary.Deletion.purge_now/3`). Cannot be undone: only a backup taken before still
  holds the data. Refused for an address that is no instance admin's,
  `{:error, :not_instance_admin}`, and as the edition refuses it
  (`c:Apiary.Edition.deletion_refusal/2`): the instance organisation, and an operator that
  still has clients, `{:error, :has_clients}`. Prints what it did and returns
  `{:ok, outcome}` or `{:error, reason}`.
  """
  @spec purge_now(String.t(), String.t()) :: {:ok, atom} | {:error, term}
  def purge_now(slug_or_id, requested_by)
      when is_binary(slug_or_id) and is_binary(requested_by) do
    Release.run(fn -> purge_now_in(String.trim(slug_or_id), requested_by) end)
  end

  @doc """
  Renders again every workspace of every organisation that has a policy, the unmanaged
  ones too, so the organisation's policy holds in each of them, as the edition holds
  it above every workspace while the instance has `organisation_policy`:
  `bin/apiary eval "ApiaryPro.Release.render_organisation_policies()"`
  (`ApiaryPro.OrganisationPolicy.render_all/0`). Each change is the instance's, by nobody,
  in the workspace's History. Safe to run again: a workspace whose documents say what
  they should already gets nothing new. An organisation one of whose workspaces cannot
  be rendered is left as it was, and the log names it. Prints what it did and returns
  `%{workspaces: n, versions: m}`.
  """
  @spec render_organisation_policies() :: %{
          workspaces: non_neg_integer,
          versions: non_neg_integer
        }
  def render_organisation_policies do
    Release.run(fn ->
      %{workspaces: workspaces, versions: versions} =
        result = ApiaryPro.OrganisationPolicy.render_all()

      IO.puts(
        "Rendered #{workspaces} workspaces under their organisation's policy: " <>
          "#{versions} new versions."
      )

      result
    end)
  end

  defp purge_now_in(slug_or_id, email) do
    admin = Apiary.Accounts.get_user_by_email(String.trim(email))

    if Apiary.Access.instance_admin?(Apiary.Accounts.Scope.for_user(admin)) do
      purge_organisation_now(slug_or_id, admin)
    else
      IO.puts("The address of the one who asked is not an instance admin's: nothing was purged.")

      {:error, :not_instance_admin}
    end
  end

  defp purge_organisation_now(slug_or_id, requested_by) do
    import Ecto.Query, only: [from: 2]

    # An id in its written form only: `Ecto.UUID.cast/1` takes any sixteen bytes for an
    # id too, and a slug may be sixteen characters long.
    query =
      case byte_size(slug_or_id) == 36 && Ecto.UUID.cast(slug_or_id) do
        {:ok, id} -> from(o in Organisation, where: o.id == ^id)
        _slug -> from(o in Organisation, where: o.slug == ^slug_or_id)
      end

    case Apiary.Repo.one(query) do
      nil ->
        IO.puts("No organisation has that slug or id: nothing was purged.")
        {:error, :not_found}

      organisation ->
        case Apiary.Deletion.purge_now(organisation, requested_by, %{
               worker: "ApiaryPro.Release.purge_now/2"
             }) do
          {:ok, :purged} = result ->
            IO.puts("Organisation #{organisation.id} is purged.")
            result

          {:ok, outcome} = result ->
            IO.puts("Organisation #{organisation.id}: #{outcome}.")
            result

          {:error, :instance_organisation} = error ->
            IO.puts(
              "That is the instance owner, which holds the instance admins: " <>
                "nothing was purged."
            )

            error

          {:error, :has_clients} = error ->
            IO.puts(
              "Not purged: it is an operator with clients. Each client is deleted first: " <>
                "nothing was purged."
            )

            error

          {:error, reason} = error ->
            IO.puts(
              "Not purged: #{Release.refusal(reason)}. Running it again goes on where it stopped."
            )

            error
        end
    end
  end
end
