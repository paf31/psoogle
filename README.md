# Pursuit

[![Build Status](https://github.com/purescript/pursuit/workflows/CI/badge.svg?branch=master)](https://github.com/purescript/pursuit/actions?query=workflow%3ACI+branch%3Amaster)

Pursuit hosts API documentation for PureScript packages. It lets you search by
package, module, and function names, as well as approximate type signatures.

Pursuit is currently deployed at <https://pursuit.purescript.org>.

Information for package authors can be found at
<https://pursuit.purescript.org/help>.

## Development

It's recommended to use `stack`: <http://docs.haskellstack.org>.

### Build

To build in development mode:

```
$ stack build
```

To build in production mode:

```
$ stack build --flag pursuit:-dev
```

### Develop

To iterate quickly during development, you can use `ghci`:

```
$ stack ghci
```

Once the REPL has loaded, you can reload the code and then update the web server:

```
> :l DevelMain
> update
```

### Web server

To run the web server on <http://localhost:3000>:

```
$ stack exec pursuit
```

You might want to add some content to the database (see [Database](#database)),
otherwise you will not be able to browse any packages. The database will be
regenerated from this data source before the server starts listening; this
can take a short time depending on how much data you have.

## Database

Pursuit currently uses the filesystem as a database, since it requires no setup
and it makes it easy to use Git and GitHub for backing up. The data directory
is set via an environment variable (see [Configuration](#configuration), the
default is `data`).

If you need some sample packages to work with, you can clone the
[pursuit-backups][pursuit-backups] repo and copy the packages you want to the
`verified/` directory. This is more convenient than manually uploading each
package.

[pursuit-backups]: https://github.com/purescript/pursuit-backups

### Database structure

The database structure is as follows:

```
/
  cache/
    packages/
      purescript-prelude/
        0.1.0/
          index.html
          docs/
            Prelude/
              index.html
  verified/
    purescript-prelude/
      0.1.0.json
      0.1.1.json
```

The `cache/` directory has files that mirror the URL structure of the web
application, and contains files which do not change and may be served as-is
without forwarding the request on to the Yesod application. See Handler.Caching
for more details.

The `verified/` directory stores uploaded packages. Each package has its own
directory, and then there is a JSON file for each version. These JSON files
each contain a serialized `Package GithubUser`; see
Language.PureScript.Docs.Types in the compiler for details about these types.

The backup process simply involves rsyncing everything in the `verified/`
directory into a git repository, making a commit, and pushing it to GitHub.

## Configuration

All configuration is done at startup via environment variables. The relevant
code is in the Settings module.

All configuration variable names start with `PURSUIT_` (eg,
`PURSUIT_APPROOT`). All configuration variables are optional; for
development, it is fine to just run `stack exec pursuit` leaving them all
unset.

See `src/Settings.hs` for more details.

## Assets

The favicon assets in `static/favicon` were taken from the [Purescript Logo](https://github.com/purescript/logo) repository.
