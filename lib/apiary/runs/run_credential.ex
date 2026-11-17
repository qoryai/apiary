defmodule Apiary.Runs.RunCredential do
  # A credential entry of a run (`Apiary.Runs.RunCredentials`): the most that a credential
  # an adapter answers for the run may reach, recorded once at the run's claim, so a later
  # start of the adapter or a change at its source changes no live run. Only
  # `issued_apply` is written later, once. It has no value. The table and its rules are
  # `20261025160500_keep_each_run_s_credential_entries`'s and
  # `20261025160600_keep_the_apply_items_of_a_run_s_first_work_credential`'s, and
  # `20261117140000_keep_a_write_run_s_push_credential_entry`'s.
  #
  #   * `name`: `work-1` for the run's work entry and `push-1` for its push entry; the run
  #     configuration lists each entry under its name
  #     (`Apiary.Policy.ComposedConfiguration`). Names say nothing of the target.
  #   * `purpose`: `:work`, the run's target, at most one per run, which the run's sessions
  #     use; `:push`, at most one per run, which only Forager's push proxy uses; `:harness`,
  #     read only.
  #   * `access`: `:read` or `:write`, what the run may do on its target: `:write` for a
  #     `:push` entry alone, `:read` for a `:work` entry (a `:work` row written before the
  #     push entry existed may have `:write`).
  #   * `connection_id` and `adapter_id`: the organisation's connection through which the
  #     target's collection came, and its adapter. A call for the work credential sends
  #     that connection's public id as `connection_id`.
  #   * `resources`: `%{"collection_id", "external_ref", "path"}` for each collection the
  #     entry covers: its row id, its ref as the adapter listed it, which a call for the
  #     work credential sends as its one resource, and the path of the run's target.
  #   * `apply`: the adapter's apply items with `{target.path}` filled
  #     (`Apiary.Integrations.ApplyTemplates`); `placeholders`: nil for none.
  #   * `issued_apply`: the apply items of the first credential the adapter issued for the
  #     entry and Qory Apiary sealed and recorded (`Apiary.Runs.WorkCredential`),
  #     nil until then. A later credential whose items differ is refused, as the gateway
  #     refuses a renewal whose items differ from those at the run's start.
  #
  # The module reference leaves out this module of the `factory` feature.
  @moduledoc false
  use Ecto.Schema

  @typedoc "A credential entry of a run."
  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "run_credentials" do
    field :name, :string
    field :purpose, Ecto.Enum, values: [:work, :harness, :push]
    field :access, Ecto.Enum, values: [:read, :write]
    field :resources, {:array, :map}
    field :apply, {:array, :map}
    field :placeholders, {:array, :string}
    field :issued_apply, {:array, :map}
    field :inserted_at, :utc_datetime_usec

    belongs_to :organisation, Apiary.Organisations.Organisation
    belongs_to :workspace, Apiary.Organisations.Workspace
    belongs_to :run, Apiary.Runs.Run
    belongs_to :connection, Apiary.Adapters.Connection
    belongs_to :adapter, Apiary.Nodes.Node
  end
end
