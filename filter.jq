# Reduce `bw list items` to the metadata the widget needs. Passwords, notes,
# TOTP seeds, card data, and identities are dropped before anything reaches
# QML. Only login items are kept.
[.[:5000][]
  | select(.type == 1)
  | {
      id: (.id // ""),
      name: (.name // ""),
      username: (.login.username // ""),
      favorite: (.favorite // false),
      hasTotp: (((.login.totp // "") | length) > 0),
      uris: [.login.uris[]?.uri // empty]
    }
]
| sort_by([(.favorite | not), (.name | ascii_downcase)])
