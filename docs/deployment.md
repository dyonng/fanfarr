# Deployment: volumes, path mapping, and mergerfs

Fanfarr's API-upload mode needs nothing from the filesystem. The local
`theme.mp3` mode writes files *into the media library*, and everything in this
document exists to serve that.

## The core constraint

Plex tells Fanfarr where a show lives using Plex's view of the filesystem. To
write `theme.mp3` beside the media, Fanfarr needs the same directory in its own
view. Those two views must be reconciled, one way or the other.

## The reference deployment

Recorded because it is the setup Fanfarr is developed against, and because it
exercises most of what follows.

- **Plex runs on bare metal**, not in a container. It therefore reports *host*
  paths, and any container that wants to act on them must see the same paths.
- **Five ext4 drives** mounted individually under `/media`, pooled by mergerfs
  into `/media/merged-storage/{TV,Movies,Music,Sets}`.
- **Sonarr and Radarr write to the individual drives** (`/tv1`..`/tv5`,
  `/movies1`..`/movies5`) rather than the pool, so they control placement.
  Plex reads the pool. Both views describe the same files.
- Everything owned by `1000:1000`, which is the `PUID`/`PGID` default.

The whole media tree is mounted at the identical path:

```yaml
volumes:
  - /media:/media:rslave
```

That single line covers the pool and the individual drives, needs no
`PATH_MAPPINGS`, and keeps working when a library is added on a new drive.

### Why `:rslave` is required here, not optional

The mergerfs pools are **separate mount points nested underneath `/media`**. A
plain bind mount of a directory does not carry nested mounts into the
container: Docker would bind `/media`, and `/media/merged-storage` would appear
as the **empty directory** that exists under the mount rather than the pooled
contents.

Nothing errors. The library simply looks empty, and there is no hint as to why.

`:rslave` propagates the nested mounts through, and additionally means a pool
remounted on the host is reflected in the container rather than going stale.

## Mounts: one per library location, *arr style

Mount each library location separately, with container paths of your choosing,
exactly as Sonarr and Radarr do:

```yaml
volumes:
  - /path/to/docker/fanfarr:/config
  - /media/the-biggest-one/MorePlex/TV:/tv1
  - /media/red-10-redemption/TV:/tv2
  - /media/thiccer-than-your-average/Plexifer/TV:/tv3
  - /media/omg-david/TV:/tv4
  - /media/big-stinky/TV:/tv5
  - /media/the-biggest-one/MorePlex/Movies:/movies1
  # ...and so on
```

There is no fixed number of mounts and no required naming. Add as many as you
have. Then register those same container paths as **root folders** in Settings.

### How Fanfarr finds anything

Plex reports paths in *its* view of the filesystem, which will not match the
container paths above -- and does not need to. Fanfarr locates an item by
matching its **directory name** across the configured root folders:

```
Plex reports:  /media/merged-storage/TV/Fleabag (2016)
                                        └──────┬──────┘
                          searched for under each root folder
                                               ↓
Found at:      /tv2/Fleabag (2016)
```

So Fanfarr never needs the library mounted at Plex's own path, and never needs
to be told which drive holds which show. Root folders are what make the
numbered-mount layout work.

They also decide *placement*. Writing to a resolved drive rather than through a
pool keeps a theme on the same disk as its episodes, and makes the temp-file
rename atomic because source and destination share a filesystem.

### `PATH_MAPPINGS`, for what root folders cannot cover

Where a Plex-reported prefix needs translating directly to a container path,
set pairs of `plex_prefix:local_prefix`, separated by `;` or newlines:

```bash
PATH_MAPPINGS=/media/merged-storage/TV:/tv;/media/merged-storage/Movies:/movies
```

Longest prefix wins, so a general rule and a specific exception coexist.
Matching is on path segments, so `/data/tv` never matches `/data/tv-4k`.
Trailing slashes are insignificant, an unmatched path passes through unchanged,
and a malformed entry is discarded rather than failing startup.

### The zero-config shortcut

Mounting a path at *itself* (`- /media:/media:rslave`) makes Fanfarr's view
identical to Plex's, so neither root folders nor `PATH_MAPPINGS` are needed to
find anything. It works, and it is the least to configure, but it grants
broader access than the explicit layout and hides which locations are actually
in use. Prefer the numbered mounts above.

## mergerfs

A mergerfs pool is an ordinary POSIX mount, so the basic case needs nothing
special: mount the pool into the container like any other volume. Four things
are worth getting right.

### Use `rslave` bind propagation

```yaml
volumes:
  - /mnt/storage:/data:rslave
```

Without it, if mergerfs is mounted (or remounted) on the host *after* the
container starts, the container keeps its original view -- usually the empty
directory that existed underneath. Nothing errors; the library simply appears
empty. `rslave` propagates host mount changes into the container.

This is the single most common mergerfs-in-Docker problem, and it is
indistinguishable from a wrong path unless you know to look.

### The reference host uses `mfs`, so EXDEV is the normal case

The pools are mounted with:

```
defaults,nonempty,allow_other,use_ino,category.create=mfs,minfreespace=20G
```

`category.create=mfs` is **not** path-preserving, and given the spread of free
space across the five drives, most new files land on whichever drive currently
has the most room -- not the drive holding the show. So a theme written into a
show's folder will *usually* land somewhere other than its episodes.

That has one consequence for us, and it is not optional: **the file writer must
handle `EXDEV` when renaming its temporary file into place.** Under a
path-preserving policy the temporary file and its target share a branch and the
rename is atomic. Here they routinely will not, and the rename fails. The
fallback is copy-then-unlink, accepting a non-atomic write rather than failing.

This is a confirmed property of the target deployment, not a hypothetical.

Changing the pool to `epmfs` would avoid it, but that is a stack-wide decision
about where *all* new files go, and it is not Fanfarr's to make. Handling EXDEV
is cheaper and correct under either policy.

### Prefer a path-preserving create policy

mergerfs chooses which underlying branch a *new* file goes to using
`category.create`. With a non-path-preserving policy such as `mfs` (most free
space), a `theme.mp3` written into a show's folder can land on a different disk
from the show's episodes.

Functionally that is fine -- the union hides it -- but it fragments the show
across disks, which is usually the thing people running mergerfs are trying to
avoid. An existing-path policy keeps the theme with its show:

```
category.create=epmfs   # existing path, most free space
```

Fanfarr cannot influence this from inside the container; it is a property of
how the pool is mounted on the host.

### Expect `EXDEV` on rename

Fanfarr writes a theme to a temporary file in the destination directory and
renames it into place, so an interrupted download never appears as a valid
`theme.mp3`. Under a path-preserving policy the temporary file and its target
share a branch and the rename is atomic as intended.

Under a non-path-preserving policy they may land on *different* branches, and
the rename fails with `EXDEV`. The file writer must therefore fall back to
copy-then-unlink when it sees `EXDEV`, accepting a non-atomic write rather than
failing outright. This is a requirement on the implementation, recorded here so
it is not discovered in the field.

### Ownership still applies

mergerfs passes ownership through to the underlying branches, so `PUID`/`PGID`
matter exactly as much as with a plain mount. Set them to the user that owns
your media, or Plex will not be able to read the themes Fanfarr writes.

## Root folders

Fanfarr can be told about the individual drives behind a pool, the way Sonarr
and Radarr are. It is optional, and it changes only *where a theme physically
lands*, never whether Plex can see it.

With no root folders configured, Fanfarr writes to the path Plex reported. On a
pool that is the pool path, which is correct -- the file appears there for
anything reading the pool -- but the pool's create policy decides which disk
holds the bytes, and under `mfs` that is usually not the disk holding the show.

Configure the underlying drives as root folders and Fanfarr resolves the pool
path to the real drive before writing:

```
/media/the-biggest-one/MorePlex/TV
/media/red-10-redemption/TV
/media/thiccer-than-your-average/Plexifer/TV
/media/omg-david/TV
/media/big-stinky/TV
```

Three things follow:

- The theme lands on the same disk as its episodes.
- The temporary-file rename becomes atomic again, because source and
  destination are on one filesystem. The `EXDEV` fallback stays for the
  unconfigured case but stops being the normal path.
- It works for anyone with libraries on separate mounts, pool or no pool.

### When a show is on more than one drive

A pool creates a show's directory on whichever branch a new episode landed on,
so the same show can exist on several drives at once. Fanfarr picks in this
order:

1. The drive that already holds a `theme.mp3`, so an update replaces the
   existing file rather than creating a second one elsewhere.
2. The drive holding the most files for that show.
3. Neither being decisive, it still picks one but marks the item **ambiguous**,
   and the dashboard says so rather than choosing silently.

## Network: do not route yt-dlp through a VPN by default

Fanfarr resolves themes from YouTube with yt-dlp, and the obvious instinct in an
*arr stack is to send that through the same VPN as the download client. Don't.

YouTube bot-checks datacenter and VPN exit addresses aggressively -- they are
shared by thousands of users and heavily flagged -- so yt-dlp through one draws
`Sign in to confirm you're not a bot`, HTTP 429 and throttling far more often
than a residential address does. Theme resolution either works or it doesn't,
and this is the single biggest factor in which.

The reason a VPN is there for the download client does not extend to this. Torrent
traffic is peer-visible, actively monitored, and generates notices. A yt-dlp fetch
is an ordinary HTTPS request to Google, indistinguishable from watching YouTube in
a browser from the same address. The volume is trivial besides: a few thousand
short audio fetches on first sync, then almost nothing.

There is also a trap in the workaround. When YouTube does start refusing anonymous
requests, the documented fix is a cookie file -- but cookies *plus* a VPN is the
worst combination available, because YouTube then sees the account authenticating
from a datacenter address, which reads as account compromise and invites a
security challenge. Cookies want to come from the same address the account
normally uses.

### Routing only yt-dlp, when you want to

This need not be a container-wide decision. `YTDLP_PROXY` sends yt-dlp through a
proxy while everything else -- Plex on the LAN, ThemerrDB -- goes direct:

```
YTDLP_PROXY=http://gluetun:8888
```

gluetun provides that proxy with `HTTPPROXY=on`. Empty by default, which means
no proxy. The setting exists so that a home address hitting rate limits is a
config change rather than a rebuild of the stack's network topology. It can
also be set from Settings, without touching compose or restarting.

## Read-only mounts

The library mount cannot be read-only if you use local theme output -- that
mode writes into it. If you use API-upload mode exclusively, a read-only mount
is fine and is a reasonable precaution.
