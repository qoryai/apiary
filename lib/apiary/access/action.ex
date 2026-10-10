defmodule Apiary.Access.Action do
  @moduledoc """
  Action is one verb of `Apiary.Access`: something a person, an access key or the instance
  may be allowed to do, named once, with everything the rest of Qory Apiary asks of it.

  - `name`: the action's atom, `:"noun.verb"`, the name the audit trail records.
  - `feature`: the feature it belongs to (`Apiary.Features`), nil for one every instance
    has. An action of a feature that is off is not found.
  - `what`: one line saying what it is, which the documentation tabulates.
  - `roles`: the roles that hold it, the rows of the role table it is in. An action no
    role holds is taken on the strength of something else, a sign-up, an invitation's
    token or a release command, and asks nothing of `Apiary.Access`.
  - `audited`: `true` when taking it leaves an entry in the audit trail (`Apiary.Audit`),
    `{:not, reason}` when it changes nothing worth one, with the reason.
  - `asked_of`: what it is asked of: `:organisation`, what the organisation owns, its
    name, its people, its trail; `:workspace`, what a workspace holds; `:account`, a
    person's account, which is no organisation's; or `:new_organisation`, an organisation
    before it exists.

  The core's actions are `Apiary.Access`'s; an edition adds its own through
  `c:Apiary.Edition.actions/0`, each an `Action` too. `Apiary.Access.action/1` finds one by
  name.
  """

  @enforce_keys [:name, :what]
  defstruct name: nil, feature: nil, what: nil, roles: [], audited: true, asked_of: :workspace

  @typedoc "What an action is asked of."
  @type asked_of :: :organisation | :workspace | :account | :new_organisation

  @typedoc "An action of `Apiary.Access`."
  @type t :: %__MODULE__{
          name: atom,
          feature: atom | nil,
          what: String.t(),
          roles: [atom],
          audited: true | {:not, String.t()},
          asked_of: asked_of
        }

  @asked_of [:organisation, :workspace, :account, :new_organisation]

  @doc """
  new/3 is the action `name`, which is `what`, with the rest from `opts`: `feature:`
  (nil), `roles:` (none), `audited:` (`true`) and `asked_of:` (`:workspace`). Raises
  `ArgumentError` for a name that is not an atom, a description that is not a string, or
  an option it does not know.
  """
  @spec new(atom, String.t(), keyword) :: t
  def new(name, what, opts \\ []) when is_atom(name) and is_binary(what) do
    action = struct!(__MODULE__, [name: name, what: what] ++ opts)

    unless action.asked_of in @asked_of,
      do: raise(ArgumentError, "#{name} is asked of #{inspect(action.asked_of)}")

    unless action.audited == true or match?({:not, reason} when is_binary(reason), action.audited),
      do: raise(ArgumentError, "#{name} is audited #{inspect(action.audited)}")

    action
  end
end
