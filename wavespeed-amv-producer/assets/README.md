# assets

`wavespeed_key.template` — an optional convenience. The scripts prefer the environment variable
WaveSpeed's own docs use:

```powershell
$env:WAVESPEED_API_KEY = '<your key>'
```

If you would rather keep it in the project, copy the template and paste your key into it:

```
cp <skill>/assets/wavespeed_key.template .wavespeed_key
```

The file holds the key and nothing else. Scripts read it into an Authorization header and never
echo, log or persist it. **If the project is under version control, add `.wavespeed_key` to
`.gitignore` before pasting the key in.**

With neither set, the scripts stop and tell you what to do — they will not guess.
