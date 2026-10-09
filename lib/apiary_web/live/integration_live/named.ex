defmodule ApiaryWeb.IntegrationLive.Named do
  @moduledoc """
  The named releases: a short fixed list of programs, each released on a forge, that
  Workspace settings › Integrations offers by name, a card each among the cards to add
  (`ApiaryWeb.IntegrationLive.Index`), beside the runtimes of the runner's catalogue
  (`Apiary.Kinds.Runtimes`) and the built-in APIs (`Apiary.Kinds.Services`), which come
  from files the app ships and need no list.

  Each entry is its `name`, as its card shows it; its `source`, a forge path such as
  `github.com/acme/tracker`, which the card's Set up fills in on Add from a release; and
  `about`, one line under the name. The person types the version, since a release is
  asked for by an exact one (`Apiary.Integrations.request_release/2`).

  The list is empty: a release joins it only once it can be added, its release carrying
  the `description.json` and `checksums.txt` Apiary reads.
  """

  @enforce_keys [:name, :source, :about]
  defstruct [:name, :source, :about]

  @type t :: %__MODULE__{name: String.t(), source: String.t(), about: String.t()}

  @doc "list/0 is the named releases, in the order their cards show."
  @spec list() :: [t()]
  def list, do: []
end
