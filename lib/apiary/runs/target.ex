defmodule Apiary.Runs.Target do
  @moduledoc """
  What the workspace's runs change, in the system it lives in: created the first time the
  workspace names it (`insert_new/3`), as the projector does from a run's labels, which
  the workspace's domain reads (`Apiary.Lingo.Domain`). Unique per workspace on system
  and path. The software domain calls a target a repository and its system a forge.

  `public_id` is the id Qory Apiary gives the target, `tg_` and 16 characters
  (`Apiary.PublicId`): its page is addressed by it, `/:org/:workspace/targets/tg_…`.
  `system` and `path` are the labels Forager sent, named after the system they come
  from. `insert_new/3` sets the id when it creates the target; a row written without one
  gets the column's default, of the same shape, read back on insert.
  """

  # With the `factory` feature:
  # `further_repositories` are the paths in its system that its runs also read, after it,
  # in the order a person put them, empty for none: read through
  # `Apiary.Targets.further_repositories/1`, written whole through
  # `Apiary.Targets.set_further_repositories/3`, which checks them.
  use Ecto.Schema

  alias Apiary.PublicId

  @label_max 256
  # C0 and DEL, C1 (U+0085, the next line, among them), and the line and paragraph
  # separators: what ends a line somewhere, in a log, a YAML comment or a terminal.
  @control ~r/[\x{00}-\x{1F}\x{7F}-\x{9F}\x{2028}\x{2029}]/u

  @doc "The most bytes a label that names a system or a path has."
  def label_max, do: @label_max

  @doc """
  A label as one that can name a target's system or path, or nil: a string of valid
  UTF-8, not empty, at most #{@label_max} bytes, with no control character (C0, DEL, C1
  with U+0085, U+2028, U+2029). A label is Forager's word. One that fails this is
  neither cleaned nor cut, since either would file the run under a target it did not
  name: the run is kept, with its labels as sent, and belongs to no target. Every domain's
  labelling rule asks here, and the projector and the wire (`Apiary.Policy.Serving`)
  both ask the domain, so they always pick the same target, or none.
  """
  @spec label(term) :: String.t() | nil
  def label(label) when is_binary(label) and label != "" and byte_size(label) <= @label_max do
    if String.valid?(label) and not Regex.match?(@control, label), do: label
  end

  def label(_label), do: nil

  @typedoc "A target the workspace's runs named."
  @type t :: %__MODULE__{}

  # Rows of one insert: nine parameters each, well below the 65,535 a query may carry.
  @insert_chunk 1_000

  @doc """
  Creates each of `targets`, `%{system:, path:}` as a domain names them
  (`Apiary.Lingo.Domain.target/2`), in the workspace `workspace_id` of the organisation
  `organisation_id`, unless the workspace has it already: one seen before keeps its row,
  its public id and its `first_seen_at`, since the conflict writes nothing. A new one is
  first seen now. The targets are inserted sorted by system and path, once each, so two
  callers that name the same targets take them in the same order. The query is kept out
  of the query log (`log: false`), since the labels may be event data.
  """
  @spec insert_new(Ecto.UUID.t(), Ecto.UUID.t(), [Apiary.Lingo.Domain.target()]) :: :ok
  def insert_new(organisation_id, workspace_id, targets) when is_list(targets) do
    now = DateTime.utc_now()

    targets
    |> Enum.map(&{&1.system, &1.path})
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.chunk_every(@insert_chunk)
    |> Enum.each(fn chunk ->
      PublicId.Insert.insert_all(
        __MODULE__,
        for {system, path} <- chunk do
          %{
            id: Ecto.UUID.generate(),
            public_id: Apiary.PublicId.generate("tg"),
            organisation_id: organisation_id,
            workspace_id: workspace_id,
            system: system,
            path: path,
            first_seen_at: now,
            inserted_at: now,
            updated_at: now
          }
        end,
        on_conflict: :nothing,
        conflict_target: [:workspace_id, :system, :path],
        log: false
      )
    end)
  end

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "targets" do
    field :public_id, :string, read_after_writes: true
    field :system, :string
    field :path, :string
    field :first_seen_at, :utc_datetime_usec
    # The target's own mode of the security policy; nil follows the workspace's. Changed
    # through `Apiary.Policy.set_mode/3`.
    field :egress_mode, :string
    # The further repositories its runs also read, after it, in order; empty for none.
    # Written whole through `Apiary.Targets.set_further_repositories/3`.
    field :further_repositories, {:array, :string}, default: []

    belongs_to :organisation, Apiary.Organisations.Organisation
    belongs_to :workspace, Apiary.Organisations.Workspace
    has_many :runs, Apiary.Runs.Run

    timestamps(type: :utc_datetime_usec)
  end
end
