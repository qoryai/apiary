defmodule Apiary.Repo.Migrations.CreatePolicyRequests do
  use Ecto.Migration

  # A request an operator sends its clients for changes to their security policy, and each
  # client's answer to it.
  #
  # `policy_requests`: the rules to add, change or remove and the mode, as the policy
  # validated them when the request was written (`changes`, an object with a `rules` array,
  # by the check), and a note of 1 to 2000 characters saying why they are needed.
  # `organisation_id` is the operator, whose purge takes its requests with it. `author_id`
  # is the person of the operator who wrote it, kept when their account is deleted, as the
  # audit trail keeps its actor. `withdrawn_at` is set once, when the operator withdraws the
  # request from the clients that have not answered it.
  #
  # `policy_request_answers`: one row per request and client, written `pending` when the
  # request is sent. `accepted`: made in the client's policy by `answered_by_id`, in the
  # workspaces of `workspace_ids`, at least one. `declined`: by `answered_by_id`, with an
  # optional `reason`. `withdrawn`: by the operator before the client answered, or because
  # the client left its operator or was dropped (`reason` `left` or `dropped`),
  # `answered_by_id` the person who did it. The checks hold each state to those fields.
  # `organisation_id` is the client, whose purge takes its answers with it; `request_id` is
  # the operator's request, whose purge takes the answers with it too, a former client's
  # among them. `workspace_ids` names the client's workspaces as they were when it accepted,
  # without a foreign key: a workspace purged since is named by an id that is gone, which
  # the page says. The partial index is a client's pending answers.
  def change do
    create table(:policy_requests, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organisation_id,
          references(:organisations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :author_id, references(:users, type: :binary_id, on_delete: :nothing), null: false
      add :note, :text, null: false
      add :changes, :map, null: false
      add :withdrawn_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:policy_requests, [:organisation_id, :inserted_at])
    create index(:policy_requests, [:author_id])

    create constraint(:policy_requests, :policy_requests_note_check,
             check: "char_length(btrim(note)) BETWEEN 1 AND 2000"
           )

    create constraint(:policy_requests, :policy_requests_changes_check,
             check:
               "jsonb_typeof(changes) = 'object' AND jsonb_typeof(changes->'rules') = 'array'"
           )

    create table(:policy_request_answers, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organisation_id,
          references(:organisations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :request_id,
          references(:policy_requests, type: :binary_id, on_delete: :delete_all),
          null: false

      add :state, :text, null: false, default: "pending"
      add :answered_by_id, references(:users, type: :binary_id, on_delete: :nothing)
      add :reason, :text
      add :workspace_ids, {:array, :binary_id}, null: false, default: []
      add :answered_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:policy_request_answers, [:request_id, :organisation_id])
    create index(:policy_request_answers, [:organisation_id, :inserted_at])

    create index(:policy_request_answers, [:answered_by_id], where: "answered_by_id IS NOT NULL")

    create index(:policy_request_answers, [:organisation_id],
             where: "state = 'pending'",
             name: :policy_request_answers_pending_index
           )

    create constraint(:policy_request_answers, :policy_request_answers_state_check,
             check: "state IN ('pending', 'accepted', 'declined', 'withdrawn')"
           )

    create constraint(:policy_request_answers, :policy_request_answers_answered_check,
             check:
               "(state = 'pending' AND answered_at IS NULL AND answered_by_id IS NULL " <>
                 "AND reason IS NULL) OR (state <> 'pending' AND answered_at IS NOT NULL)"
           )

    create constraint(:policy_request_answers, :policy_request_answers_workspaces_check,
             check:
               "(state = 'accepted' AND cardinality(workspace_ids) > 0 AND reason IS NULL) " <>
                 "OR (state <> 'accepted' AND cardinality(workspace_ids) = 0)"
           )

    create constraint(:policy_request_answers, :policy_request_answers_reason_check,
             check: "reason IS NULL OR char_length(reason) <= 500"
           )
  end
end
