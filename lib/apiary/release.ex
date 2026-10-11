defmodule Apiary.Release do
  @moduledoc """
  Release tasks that run without Mix: migrations for `bin/migrate` and for
  `Apiary.Release.Migrator` at boot, the commands of whoever runs the instance
  (`bin/apiary eval "Apiary.Release.…"`), and helpers that production configuration
  evaluates at runtime.

  Whoever can run a command controls the instance already, so a command asks nobody's
  role. What it changes in an organisation is recorded in that organisation's trail, by
  the instance. The instance admins are the owners of the instance's organisation, the
  one the instance's first user signed up with
  (`c:Apiary.Edition.instance_organisation_id/0`, `Apiary.Access.instance_admin?/1`):
  `grant_instance_admin/2` and `revoke_instance_admin/1` make and unmake one, for a
  scripted install, which claims a fresh instance, and for recovery when none is left.
  `password_link/1` prints a one-time link that sets an account's password.
  `accept_signing_key/0` records a new signing key's fingerprint, for the boot's key
  check (`Apiary.KeyCheck`). An edition's own commands run the way these do (`run/1`).
  """
  @app :apiary

  @doc """
  Runs every pending migration, `bin/migrate`'s and `Apiary.Release.Migrator`'s at boot:
  the core's and the edition's folders (`c:Apiary.Edition.migrations_paths/0`), which
  Ecto merges by version into one sequence, and then the edition's step after them
  (`c:Apiary.Edition.after_migrate/0`), on the same repository. Raises on a migration that
  fails, so the step after them never runs on a schema half migrated.
  """
  @spec migrate() :: :ok
  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, :ok, _} =
        Ecto.Migrator.with_repo(repo, fn repo ->
          Ecto.Migrator.run(repo, Apiary.Edition.migrations_paths(), :up, all: true)
          :ok = Apiary.Edition.after_migrate()
        end)
    end

    :ok
  end

  @doc """
  Rolls `repo` back to `version`, over the core's and the edition's migrations
  (`c:Apiary.Edition.migrations_paths/0`):
  `bin/apiary eval 'Apiary.Release.rollback(Apiary.Repo, 20260927000100)'`. The edition's
  step after migrating is not run: it belongs to the schema the migrations bring, not to
  an older one.
  """
  @spec rollback(module, integer) :: :ok
  def rollback(repo, version) do
    load_app()

    {:ok, _, _} =
      Ecto.Migrator.with_repo(
        repo,
        &Ecto.Migrator.run(&1, Apiary.Edition.migrations_paths(), :down, to: version)
      )

    :ok
  end

  @doc """
  Projects runs again from their events, as `mix apiary.rebuild` does where there is Mix:
  `bin/apiary eval "Apiary.Release.rebuild()"`: every run, `batch:` for the batch size.
  See `Apiary.Runs.Rebuild`.
  """
  def rebuild(opts \\ []) do
    load_app()

    for repo <- repos() do
      {:ok, result, _} =
        Ecto.Migrator.with_repo(repo, fn _repo ->
          # A projection announces itself; outside the running application nobody listens,
          # but the name has to exist.
          {:ok, pubsub} =
            Supervisor.start_link([{Phoenix.PubSub, name: Apiary.PubSub}], strategy: :one_for_one)

          result = Apiary.Runs.Rebuild.run(opts)
          Supervisor.stop(pubsub)
          result
        end)

      result
    end
  end

  @doc """
  Renders every managed workspace's run configurations again, as
  `mix apiary.policy.rerender` does where there is Mix:
  `bin/apiary eval "Apiary.Release.policy_rerender()"`. See
  `Apiary.Policy.rerender_all/0`.
  """
  def policy_rerender do
    load_app()

    for repo <- repos() do
      {:ok, result, _} =
        Ecto.Migrator.with_repo(repo, fn _repo ->
          # A new version is announced; outside the running application nobody listens,
          # but the name has to exist.
          {:ok, pubsub} =
            Supervisor.start_link([{Phoenix.PubSub, name: Apiary.PubSub}], strategy: :one_for_one)

          result = Apiary.Policy.rerender_all()
          Supervisor.stop(pubsub)
          result
        end)

      result
    end
  end

  @doc """
  Runs the retention job now, as `mix apiary.prune` does where there is Mix:
  `bin/apiary eval "Apiary.Release.prune()"`. `dry_run: true` deletes nothing and prints
  the same counts. See `Apiary.Retention`.
  """
  def prune(opts \\ []) do
    load_app()

    for repo <- repos() do
      {:ok, result, _} =
        Ecto.Migrator.with_repo(repo, fn _repo ->
          Apiary.Retention.prune_all(Keyword.put_new(opts, :trigger, "manual"))
        end)

      case result do
        {:ok, []} -> IO.puts("No workspace has a retention setting: nothing to prune.")
        {:ok, results} -> Enum.each(results, &IO.puts(Apiary.Retention.sentence(&1)))
        {:error, :locked} -> IO.puts("The retention job is already running on this database.")
      end

      result
    end
  end

  @doc """
  Deletes the account whose email address is `email`, for whoever runs the instance, with
  shell access: `bin/apiary eval 'Apiary.Release.delete_account("dana@example.com")'`.
  The same rules as a person deleting their own (`Apiary.Accounts.delete_user/2`): the
  account becomes a tombstone, its memberships end, each an entry in its organisation's
  trail, here by the instance; refused while the person is the only owner of an
  organisation, which the output names by id. Prints what it did and returns
  `{:ok, user_id}` or `{:error, reason}`.
  """
  def delete_account(email) when is_binary(email) do
    run(fn -> delete_account_now(String.trim(email)) end)
  end

  defp delete_account_now(email) do
    alias Apiary.{Accounts, Organisations}

    case Accounts.get_user_by_email(email) do
      nil ->
        IO.puts("No account has that email address: nothing was deleted.")
        {:error, :not_found}

      user ->
        case Accounts.delete_user(user, origin: %{worker: "Apiary.Release.delete_account/1"}) do
          {:ok, {tombstone, _tokens}} ->
            IO.puts("Account #{tombstone.id} is deleted; its row stays without personal data.")
            {:ok, tombstone.id}

          {:error, :last_owner} ->
            ids = user |> Organisations.sole_owned_organisations() |> Enum.map(& &1.id)

            IO.puts(
              "Not deleted: the account is the only owner of the organisation(s) " <>
                Enum.join(ids, ", ") <>
                ". Make another member an owner, or delete the organisation, first."
            )

            {:error, :last_owner}

          {:error, reason} ->
            IO.puts("Not deleted: #{refusal(reason)}.")
            {:error, reason}
        end
    end
  end

  @doc """
  Makes the account whose email address is `email` an owner of the instance's
  organisation, an instance admin:
  `bin/apiary eval 'Apiary.Release.grant_instance_admin("dana@example.com")'`. For a
  scripted install, and for recovery when no instance admin is left. A membership at
  owner when the account has none there, its level made owner when it has one; an entry
  in the organisation's trail, `instance_admin.grant`, by the instance
  (`Apiary.Organisations.grant_instance_admin/2`). The account must exist: the person
  signs up with an invitation, or at the sign-up page where the instance allows it, first.
  Prints what it did and returns `{:ok, membership}` or `{:error, reason}`.

  On an instance that is not set up yet it sets the instance up instead, from a shell, in
  place of its set-up link (`Apiary.Setup`): it is the instance's first sign-up, with
  `email` and `organisation_name`, which creates the instance's organisation, its
  workspace Main and the account as its owner, and marks the set-up code used, so the
  link works no more. With mail (`Apiary.Mail.configured?/0`) it sends the account its
  log-in link, as the sign-up page does; `{:ok, :created}`. Should that mail not go out,
  the instance is set up all the same, the output says so, without the address or the
  link, and says to ask for a link at `/users/log-in`: `{:ok, :created_without_mail}`.
  Without mail it prints a password link for the account instead, which works once, for an
  hour (`password_link/1`), and never the address: `{:ok, :created_without_mail}`.
  `bin/apiary eval 'Apiary.Release.grant_instance_admin("dana@example.com", "Acme")'`.
  The organisation's name is required then, `{:error, :organisation_name_required}`
  without it. Should the set-up link have been used first, the command does what it does
  on any instance that has its organisation.

  The claim is `Apiary.Setup.claim/3`.
  """
  def grant_instance_admin(email, organisation_name \\ nil) when is_binary(email) do
    run(fn -> grant_instance_admin_now(String.trim(email), organisation_name) end)
  end

  defp grant_instance_admin_now(email, organisation_name) do
    if Apiary.Edition.instance_organisation_id(),
      do: grant_existing(email),
      else: claim_instance(email, organisation_name)
  end

  defp claim_instance(_email, name) when name in [nil, ""] do
    IO.puts(
      "Nobody has signed up yet. Give the name of the organisation to create, for example: " <>
        ~s{Apiary.Release.grant_instance_admin("dana@example.com", "Acme")}
    )

    {:error, :organisation_name_required}
  end

  defp claim_instance(email, name) do
    case Apiary.Setup.claim(email, name, %{worker: "Apiary.Release.grant_instance_admin/2"}) do
      {:ok, user, :sent} ->
        IO.puts(Apiary.Setup.message(user, :sent))
        {:ok, :created}

      # No mail is set: the log-in link had nowhere to go, and a password link takes its
      # place, on this terminal.
      {:ok, user, :not_sent} ->
        if Apiary.Mail.configured?() do
          IO.puts(Apiary.Setup.message(user, :not_sent))
        else
          print_password_link(user, :first_admin, "Apiary.Release.grant_instance_admin/2")
        end

        {:ok, :created_without_mail}

      # The set-up link was used a moment before: the instance has its admin.
      {:error, :instance_claimed} ->
        grant_existing(email)

      {:error, %Ecto.Changeset{} = changeset} ->
        IO.puts("Not created: #{changeset_errors(changeset)}.")
        {:error, :invalid}
    end
  end

  defp grant_existing(email) do
    with {:ok, user} <- account(email) do
      case Apiary.Organisations.grant_instance_admin(user, %{
             worker: "Apiary.Release.grant_instance_admin/2"
           }) do
        {:ok, %{membership: membership, granted?: false}} ->
          IO.puts("The account is an instance admin already: nothing was changed.")
          {:ok, membership}

        {:ok, %{membership: membership}} ->
          IO.puts("The account #{membership.user_id} is an instance admin now.")
          {:ok, membership}

        {:error, reason} ->
          IO.puts("Not granted: #{refusal(reason)}.")
          {:error, reason}
      end
    end
  end

  # A changeset's errors by field, with the messages and no value: the address stays off
  # the terminal's scrollback. Each message is filled in by
  # `Apiary.Setup.error_messages/1`, which never turns an option such as a list of
  # fields into text.
  defp changeset_errors(changeset) do
    changeset
    |> Apiary.Setup.error_messages()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.map_join("; ", fn {field, messages} -> "#{field} #{Enum.join(messages, ", ")}" end)
  end

  @doc """
  Prints a one-time link that sets the password of the account whose email address is
  `email`, for whoever runs the instance, with shell access, when its person has lost
  their password: `bin/apiary eval 'Apiary.Release.password_link("dana@example.com")'`.
  Whoever has the link may set the account's password, so it goes to that person alone.

  It works once, for an hour, mail or not, and ends the account's link before, if any
  (`Apiary.Accounts.build_password_link/3`); setting the password ends every session of
  the account. An entry in the instance's organisation's trail, `account.password_link`,
  by the instance. Prints the link and until when it works, never the address; returns
  `{:ok, user_id}` or `{:error, reason}`.
  """
  def password_link(email) when is_binary(email) do
    run(fn -> password_link_now(String.trim(email)) end)
  end

  defp password_link_now(email) do
    with {:ok, user} <- account(email),
         {:ok, _url} <- print_password_link(user, :account, "Apiary.Release.password_link/1"),
         do: {:ok, user.id}
  end

  # A password link for `user`, by the instance, from `worker`, printed on the terminal of
  # whoever runs the command, and nowhere else: neither the log nor the trail holds it.
  defp print_password_link(user, why, worker) do
    scope =
      nil
      |> Apiary.Accounts.Scope.for_instance()
      |> Apiary.Accounts.Scope.put_origin(%{worker: worker})

    case Apiary.Accounts.build_password_link(scope, user, &"#{public_url()}/users/password/#{&1}") do
      {:ok, url, expires_at} ->
        IO.puts(password_link_message(user, why, expires_at) <> "\n\n    " <> url <> "\n")
        {:ok, url}

      {:error, reason} ->
        IO.puts("No password link was made: #{refusal(reason)}.")
        {:error, reason}
    end
  end

  defp password_link_message(user, :first_admin, expires_at),
    do:
      "The account #{user.id} is the instance's first admin. No mail is set, so it has " <>
        "no log-in link: open this link to set its password. It works once, until " <>
        "#{utc(expires_at)}."

  defp password_link_message(user, :account, expires_at),
    do:
      "A password link for the account #{user.id}. It works once, until #{utc(expires_at)}; " <>
        "send it to that person alone."

  defp utc(at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M UTC")

  # The instance's address for a link printed here: the endpoint's, when it runs, else the
  # one its configuration gives, as `bin/apiary eval` has no endpoint running.
  defp public_url do
    if :persistent_term.get({Phoenix.Endpoint, ApiaryWeb.Endpoint}, nil) do
      ApiaryWeb.Endpoint.url()
    else
      url = Application.get_env(:apiary, ApiaryWeb.Endpoint, [])[:url] || []

      URI.to_string(%URI{
        scheme: url[:scheme] || "https",
        host: url[:host] || "localhost",
        port: url[:port]
      })
    end
  end

  @doc """
  Makes the instance admin whose email address is `email` a member of the instance's
  organisation, no admin any more:
  `bin/apiary eval 'Apiary.Release.revoke_instance_admin("dana@example.com")'`. They stay in
  the instance's own organisation, where an owner removes them if they should leave; an
  entry in its trail, `instance_admin.revoke`, by the instance
  (`Apiary.Organisations.revoke_instance_admin/2`). Refused for the last instance admin,
  `{:error, :last_owner}`: grant another first. Prints what it did and returns
  `{:ok, membership}` or `{:error, reason}`.
  """
  def revoke_instance_admin(email) when is_binary(email) do
    run(fn -> revoke_instance_admin_now(String.trim(email)) end)
  end

  defp revoke_instance_admin_now(email) do
    with {:ok, user} <- account(email) do
      case Apiary.Organisations.revoke_instance_admin(user, %{
             worker: "Apiary.Release.revoke_instance_admin/1"
           }) do
        {:ok, membership} ->
          IO.puts("The account #{membership.user_id} is no instance admin any more.")
          {:ok, membership}

        {:error, :last_owner} ->
          IO.puts("Not revoked: the account is the last instance admin. Grant another first.")
          {:error, :last_owner}

        {:error, :not_owner} ->
          IO.puts("The account is not an instance admin: nothing was changed.")
          {:error, :not_owner}

        {:error, reason} ->
          IO.puts("Not revoked: #{refusal(reason)}.")
          {:error, reason}
      end
    end
  end

  defp account(email) do
    case Apiary.Accounts.get_user_by_email(email) do
      nil ->
        IO.puts("No account has that email address: nothing was changed.")
        {:error, :not_found}

      user ->
        {:ok, user}
    end
  end

  @doc """
  Records the fingerprint of the current signing key, the one `APIARY_SIGNING_SECRET`
  makes, as the instance's, for a change of signing key on purpose:
  `bin/apiary eval 'Apiary.Release.accept_signing_key()'`. The boot's key check
  (`Apiary.KeyCheck`) then starts with the new key, and every machine has to pin it again.
  The way the docs give is `APIARY_ACCEPT_SIGNING_FINGERPRINT`, which the key check reads
  at boot; this command stays for support. `eval` does not start the application, so the
  check that refused the boot does not refuse this; and a refused boot leaves no running
  container, so it runs in a one-off container of the same release. The check of
  `APIARY_ENCRYPTION_SECRET` is left as it is. Prints the new fingerprint, public by
  design, and returns `{:ok, fingerprint}`.
  """
  @spec accept_signing_key() :: {:ok, String.t()}
  def accept_signing_key do
    run(fn ->
      fingerprint = Apiary.KeyCheck.accept_signing_key()

      IO.puts(Apiary.KeyCheck.accepted_message(fingerprint))

      {:ok, fingerprint}
    end)
  end

  @doc """
  run/1 runs `fun` as a release command: with the application loaded, on the release's
  repository, and with the name its changes announce on (`Apiary.PubSub`), started for
  the command where the application is not running. `fun`'s answer. For the commands of
  this module, and an edition's.
  """
  @spec run((-> result)) :: result when result: term
  def run(fun) when is_function(fun, 0) do
    load_app()

    for repo <- repos() do
      {:ok, result, _} = Ecto.Migrator.with_repo(repo, fn _repo -> with_pubsub(fun) end)
      result
    end
    |> List.first()
  end

  @doc """
  refusal/1 is what a refusal says on the terminal of whoever runs the instance: an atom's
  name, and nothing of a changeset or an exception, which may hold an email address.
  """
  @spec refusal(term) :: String.t()
  def refusal(reason) when is_atom(reason), do: Atom.to_string(reason)
  def refusal(_reason), do: "the database refused the change"

  # Outside the running application nobody listens to what a change announces, but the
  # name has to exist; inside it, it does.
  defp with_pubsub(fun) do
    if Process.whereis(Apiary.PubSub) do
      fun.()
    else
      {:ok, pubsub} =
        Supervisor.start_link([{Phoenix.PubSub, name: Apiary.PubSub}], strategy: :one_for_one)

      try do
        fun.()
      after
        Supervisor.stop(pubsub)
      end
    end
  end

  @doc """
  True when `PUBLIC_URL` is plain `http://`.

  `config/prod.exs` passes this to `Plug.SSL` as an `:exclude` condition, so an
  instance published over plain HTTP (a LAN, a trial on one machine) is not redirected
  to an HTTPS address that does not exist. With an `https://` public URL every request
  is redirected unless the reverse proxy sends `X-Forwarded-Proto: https`.
  """
  def plain_http?(_conn) do
    Application.get_env(@app, :public_url_scheme) == "http"
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    # Many platforms require SSL when connecting to the database
    Application.ensure_all_started(:ssl)
    Application.ensure_loaded(@app)
  end
end
