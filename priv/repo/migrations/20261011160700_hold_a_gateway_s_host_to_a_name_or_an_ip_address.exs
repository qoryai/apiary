defmodule Apiary.Repo.Migrations.HoldAGatewaySHostToANameOrAnIpAddress do
  use Ecto.Migration

  # A gateway's address is `https://`, a host and an optional port, 1 to 65535, and
  # nothing after them (`Apiary.Nodes.Node.validate_url/1`). The host is a DNS name, an
  # IPv4 address or an IPv6 address in brackets: the check before let any character of a
  # URI's host through, `;`, `$`, `(`, `)`, `'`, `&`, `*`, `!`, `=`, `+`, `,` and `~` among
  # them. A DNS name is labels of letters, digits and `-`, 1 to 63 characters each,
  # neither starting nor ending with `-`, the last not all digits, 253 characters at most
  # with an optional trailing dot. `nodes_url_check` is re-created to say so, NOT VALID,
  # so the change scans no row under a lock that blocks writes to `nodes`; the next
  # migration validates it, and refuses while a gateway's address is outside it.

  @label "[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?"
  @name "(?=[A-Za-z0-9.-]{1,253}\\.?(:|$))(#{@label}\\.)*(?![0-9]+\\.?(:|$))#{@label}\\.?"

  @octet "(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])"
  @ipv4 "#{@octet}\\.#{@octet}\\.#{@octet}\\.#{@octet}"

  # Each way of writing eight groups of 16 bits, with `::` for one or more groups of
  # zeros, and the last two as an IPv4 address.
  @h "[0-9A-Fa-f]{1,4}"
  @ipv6 Enum.join(
          [
            "(#{@h}:){7}#{@h}",
            "::((#{@h}:){0,6}#{@h})?",
            "#{@h}::((#{@h}:){0,5}#{@h})?",
            "#{@h}(:#{@h}){1}::((#{@h}:){0,4}#{@h})?",
            "#{@h}(:#{@h}){2}::((#{@h}:){0,3}#{@h})?",
            "#{@h}(:#{@h}){3}::((#{@h}:){0,2}#{@h})?",
            "#{@h}(:#{@h}){4}::((#{@h}:){0,1}#{@h})?",
            "#{@h}(:#{@h}){5}::(#{@h})?",
            "#{@h}(:#{@h}){6}::",
            "(#{@h}:){6}#{@ipv4}",
            "::(#{@h}:){0,5}#{@ipv4}",
            "#{@h}::(#{@h}:){0,4}#{@ipv4}",
            "#{@h}(:#{@h}){1}::(#{@h}:){0,3}#{@ipv4}",
            "#{@h}(:#{@h}){2}::(#{@h}:){0,2}#{@ipv4}",
            "#{@h}(:#{@h}){3}::(#{@h}:){0,1}#{@ipv4}",
            "#{@h}(:#{@h}){4}::#{@ipv4}"
          ],
          "|"
        )

  @port "([1-9][0-9]{0,3}|[1-5][0-9]{4}|6[0-4][0-9]{3}|65[0-4][0-9]{2}|655[0-2][0-9]|6553[0-5])"

  @url "^https://(#{@name}|#{@ipv4}|\\[(#{@ipv6})\\])(:#{@port})?$"

  def up do
    drop constraint(:nodes, :nodes_url_check)

    execute """
    ALTER TABLE nodes ADD CONSTRAINT nodes_url_check CHECK (
      (kind = 'gateway') = (url IS NOT NULL) AND
      (url IS NULL OR (char_length(url) <= 2048 AND url ~ '#{@url}'))
    ) NOT VALID
    """
  end

  def down do
    drop constraint(:nodes, :nodes_url_check)

    create constraint(:nodes, :nodes_url_check,
             check:
               "(kind = 'gateway') = (url IS NOT NULL) AND " <>
                 "(url IS NULL OR (char_length(url) <= 2048 AND " <>
                 "url ~ '^https://[^/?#@[:space:]]+$'))"
           )
  end
end
