defmodule Apiary.Repo.Migrations.RemoveCredentialsFromPolicyRequests do
  use Ecto.Migration

  # The security policy no longer names credentials (the core's
  # `20261003222524_remove_credentials_from_the_security_policy`), so a policy request
  # that asks for one asks for what no client can accept, and its history reads a change
  # the policy does not know. The requests whose `changes` hold a rule of kind
  # `credential`, pending or answered, are deleted, and their answers with them; the trail
  # keeps its entries. A request is one whole the operator wrote and sent: it is not
  # rewritten to the hosts that are left.
  #
  # Down puts nothing back: the requests deleted stay deleted.
  def up do
    execute """
    DELETE FROM policy_requests
    WHERE EXISTS (
      SELECT 1 FROM jsonb_array_elements(changes->'rules') AS entry
      WHERE entry->'rule'->>'kind' = 'credential'
    )
    """
  end

  def down, do: :ok
end
