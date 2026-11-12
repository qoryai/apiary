defmodule ApiaryPro.Flags do
  # Flags hide functionality that is built and not shown, for the whole instance: off by
  # default, read from the application's config, and never per organisation, as a feature
  # is (`Apiary.Features`). A flag that is off hides what it gates as a path that does not
  # exist. Not in the published documentation: what a flag hides is not named there.
  @moduledoc false

  @transfers :transfers
  @operator_infrastructure :operator_infrastructure
  @feature_visibility :feature_visibility

  # transfers?/0 says whether an organisation's owners may offer it to an operator and
  # withdraw that offer, an operator's owners may accept an organisation offered to it,
  # and a client's owners may leave its operator (`organisation.transfer`,
  # `organisation.withdraw_transfer`, `client.accept`, `organisation.leave_operator`). Off
  # by default: `config :apiary_pro, :transfers, true` turns it on. While it is off,
  # `ApiaryPro.Access` answers each of these actions not found, for everyone, so no page,
  # item or path offers them, an offer made before included; their audit entries still
  # read as they did.
  #
  # A process may override the config for itself and the processes it starts
  # (`put_transfers/1`): the override is read from the process's dictionary, then from that
  # of each process in its `$callers`, which a `Task` and a LiveView under test carry. So a
  # test turns the flag on for its processes alone, and tests run at once keep theirs
  # apart.
  @doc false
  @spec transfers?() :: boolean
  def transfers? do
    case override(@transfers) do
      nil -> Application.get_env(:apiary_pro, @transfers, false) == true
      on? -> on?
    end
  end

  # put_transfers/1 overrides `transfers?/0` for the calling process and the processes
  # whose `$callers` name it, until the process ends or puts it again. For tests. `:ok`.
  @doc false
  @spec put_transfers(boolean) :: :ok
  def put_transfers(on?) when is_boolean(on?) do
    Process.put(key(@transfers), on?)
    :ok
  end

  # operator_infrastructure?/0 says whether an operator owns its clients: its owners act
  # as owners in each client and its admins as admins, its members read; a client's first
  # person is invited as its admin, and nobody in a client is made an owner; workspaces,
  # nodes and access keys in a client are the operator's to make and remove; only the
  # operator's owners lock and unlock a client's workspace rules, change or remove a
  # locked one, and change the client's organisation policy, refused to its owners made
  # before the switch, and the refusals name the operator; and Drop is hidden. Off by
  # default: `config :apiary_pro, :operator_infrastructure, true` turns it on. While it
  # is off, everything is as it was: the operator's people read its clients and change
  # nothing there, the first person of a client is its owner, and the actions of the
  # first admin's invitation are not found, for everyone (`ApiaryPro.Access`).
  #
  # The override works as `transfers?/0`'s: for the process that puts it and the
  # processes whose `$callers` name it. What wins: the override the process put, then its
  # callers', then the config. `ApiaryPro.Access.check/3` reads it once and passes it to the
  # steps of its answer; `ApiaryPro.Access.hidden?/1` reads it for a page;
  # `ApiaryPro.Access.role/1` reads it again where the core calls for the role, and so does
  # the check run again for someone in both.
  @doc false
  @spec operator_infrastructure?() :: boolean
  def operator_infrastructure? do
    case override(@operator_infrastructure) do
      nil -> Application.get_env(:apiary_pro, @operator_infrastructure, false) == true
      on? -> on?
    end
  end

  # put_operator_infrastructure/1 overrides `operator_infrastructure?/0` for the calling
  # process and the processes whose `$callers` name it, until the process ends or puts it
  # again. For tests. `:ok`.
  @doc false
  @spec put_operator_infrastructure(boolean) :: :ok
  def put_operator_infrastructure(on?) when is_boolean(on?) do
    Process.put(key(@operator_infrastructure), on?)
    :ok
  end

  # feature_visibility?/0 says whether a feature below the instance is shown or hidden to
  # people by who they are, not only by where they are (`ApiaryPro.Features.hidden/1`): a
  # person who holds a level in a client's operator sees in the client what the operator
  # is shown, and an instance admin who reaches an organisation through the instance sees
  # every feature the instance has. With it on, the Features pages, the Clients list and
  # the Activity page say "shown" and "hidden" for what they say "grant" and "take away"
  # with it off, and a change of what an organisation is shown is recorded with
  # `shown: true` in its entry's details. Off by default:
  # `config :apiary_pro, :feature_visibility, true` turns it on. While it is off, a person
  # is not shown what the organisation they are in is not shown, whoever they are, as
  # before.
  #
  # The override works as `transfers?/0`'s: for the process that puts it and the
  # processes whose `$callers` name it.
  @doc false
  @spec feature_visibility?() :: boolean
  def feature_visibility? do
    case override(@feature_visibility) do
      nil -> Application.get_env(:apiary_pro, @feature_visibility, false) == true
      on? -> on?
    end
  end

  # put_feature_visibility/1 overrides `feature_visibility?/0` for the calling process and
  # the processes whose `$callers` name it, until the process ends or puts it again. For
  # tests. `:ok`.
  @doc false
  @spec put_feature_visibility(boolean) :: :ok
  def put_feature_visibility(on?) when is_boolean(on?) do
    Process.put(key(@feature_visibility), on?)
    :ok
  end

  defp override(flag) do
    key = key(flag)

    case Process.get(key) do
      nil ->
        Enum.reduce_while(Process.get(:"$callers", []), nil, fn caller, nil ->
          case callers_override(caller, key) do
            nil -> {:cont, nil}
            on? -> {:halt, on?}
          end
        end)

      on? ->
        on?
    end
  end

  defp callers_override(pid, key) when is_pid(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dictionary} ->
        case List.keyfind(dictionary, key, 0) do
          {^key, on?} -> on?
          nil -> nil
        end

      nil ->
        nil
    end
  end

  defp callers_override(_name, _key), do: nil

  defp key(flag), do: {__MODULE__, flag}
end
