defmodule Apiary.Repo.Migrations.KeepWhereQoryApiaryCallsAnAdapter do
  use Ecto.Migration

  # Where Qory Apiary calls an adapter, as the adapter's latest start-up declared it
  # (`Apiary.Adapters.declare/2`, the integration contract's `adapter.schema.json`): on
  # its node, `call_url`, an https address of at most 2,048 characters with no user
  # information, no whitespace, no query and no fragment, whose path ends with `/`; and
  # `call_instance_id`, the `X-Qory-Instance-Id` of the start-up that declared it, which
  # each call is signed for: 1 to 64 letters, digits, `.`, `_` and `-`, a letter or a
  # digit first. Both NULL while the adapter declares none, and on every other node
  # (`nodes_call_url_check`).
  #
  # NULL for every row there already, and adding a column with no default rewrites no row.
  # The check is added NOT VALID, so adding it takes no scan of `nodes` under its lock; the
  # next migration validates it.
  @call_url "'^https://[^/?#@[:space:]]+/([^?#[:space:]]*/)?$'"
  @instance_id "'^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'"

  def up do
    alter table(:nodes) do
      add :call_url, :text
      add :call_instance_id, :text
    end

    execute """
    ALTER TABLE nodes ADD CONSTRAINT nodes_call_url_check CHECK (
      (call_url IS NULL AND call_instance_id IS NULL) OR (
        kind = 'adapter' AND
        call_url IS NOT NULL AND
        call_instance_id IS NOT NULL AND
        char_length(call_url) <= 2048 AND
        call_url ~ #{@call_url} AND
        call_instance_id ~ #{@instance_id}
      )
    ) NOT VALID
    """
  end

  def down do
    execute "ALTER TABLE nodes DROP CONSTRAINT nodes_call_url_check"

    alter table(:nodes) do
      remove :call_url
      remove :call_instance_id
    end
  end
end
