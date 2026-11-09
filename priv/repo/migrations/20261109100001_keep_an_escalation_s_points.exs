defmodule Apiary.Repo.Migrations.KeepAnEscalationSPoints do
  use Ecto.Migration

  # `escalations.points` replaces `escalations.gaps`: what a person reads in the block
  # "What the run needs from you", a JSON array of `{text, action, question?}` objects,
  # with `action` `answer` or `run_again`. A run writes them in its verdict
  # (`verdict.schema.json`), and Qory Apiary writes one for a cause it sets itself.
  #
  # The gaps of an escalation `escalate` are the agent's text, which nothing else keeps:
  # each of its non-empty lines becomes a point `run_again`, at most 20, as a run's
  # verdict has them. The page writes the points of every other cause from what the stage
  # reads (`Apiary.Stages`), so their gaps are dropped. Down writes the point texts of an
  # escalation `escalate` back as its gaps, one per line.
  def up do
    alter table(:escalations) do
      add :points, :jsonb, null: false, default: fragment("'[]'::jsonb")
    end

    flush()

    execute("""
    UPDATE escalations AS e
    SET points = p.points
    FROM (
      SELECT id,
             jsonb_agg(jsonb_build_object('text', line, 'action', 'run_again') ORDER BY n)
               AS points
      FROM (
        SELECT e.id, btrim(l.line, E' \\t\\r') AS line,
               row_number() OVER (PARTITION BY e.id ORDER BY l.n) AS n
        FROM escalations AS e,
             regexp_split_to_table(e.gaps, E'\\n') WITH ORDINALITY AS l(line, n)
        WHERE e.cause = 'escalate' AND btrim(l.line, E' \\t\\r') <> ''
      ) AS lines
      WHERE n <= 20
      GROUP BY id
    ) AS p
    WHERE e.id = p.id
    """)

    alter table(:escalations) do
      remove :gaps
    end
  end

  def down do
    alter table(:escalations) do
      add :gaps, :text
    end

    flush()

    execute("""
    UPDATE escalations
    SET gaps = (
      SELECT string_agg(p.point ->> 'text', E'\\n' ORDER BY p.n)
      FROM jsonb_array_elements(points) WITH ORDINALITY AS p(point, n)
    )
    WHERE cause = 'escalate' AND jsonb_array_length(points) > 0
    """)

    alter table(:escalations) do
      remove :points
    end
  end
end
