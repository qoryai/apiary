defmodule Apiary.Repo.Migrations.HoldAGatewaySAddressToHttps do
  use Ecto.Migration

  # A gateway's address is `https://`, a host and an optional port, and nothing after
  # them: a run key names the gateway by it, and only over TLS (`Apiary.Nodes.Node`,
  # `Apiary.Runs.RunKey`). `nodes_url_check` is re-created to say so, NOT VALID, so the
  # change scans no row under a lock that blocks writes to `nodes`; the next migration
  # validates it. A gateway recorded at an `http://` address before must be given an
  # `https://` one for that validation to pass.
  def up do
    drop constraint(:nodes, :nodes_url_check)

    execute """
    ALTER TABLE nodes ADD CONSTRAINT nodes_url_check CHECK (
      (kind = 'gateway') = (url IS NOT NULL) AND
      (url IS NULL OR (char_length(url) <= 2048 AND url ~ '^https://[^/?#@[:space:]]+$'))
    ) NOT VALID
    """
  end

  def down do
    drop constraint(:nodes, :nodes_url_check)

    create constraint(:nodes, :nodes_url_check,
             check:
               "(kind = 'gateway') = (url IS NOT NULL) AND " <>
                 "(url IS NULL OR (char_length(url) <= 2048 AND " <>
                 "url ~ '^https?://[^/?#@[:space:]]+$'))"
           )
  end
end
