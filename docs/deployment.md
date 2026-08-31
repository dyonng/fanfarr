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

## Recommended: make the paths identical

Mount your library at the **same container path in both Plex and Fanfarr**:

```yaml
# in your Plex service
volumes:
  - /mnt/storage:/data

# in Fanfarr
volumes:
  - /mnt/storage:/data
```

No configuration, no translation, and it scales to any number of libraries
because Fanfarr never needs to know what is underneath. This is the layout the
TRaSH guides recommend for the *arr stack generally, and it is worth adopting
even if you only run Fanfarr.

Once paths match, adding a library is purely a Plex concern.

## Fallback: path mapping

When the paths cannot match -- Plex on bare metal, or an existing stack you do
not want to re-plumb -- set `PATH_MAPPINGS`. Pairs are `plex_prefix:local_prefix`,
separated by `;` or newlines:

```bash
PATH_MAPPINGS=/data:/media
```

```bash
# Multiple libraries, and a specific exception. The longest matching prefix
# wins, so the anime rule beats the general one.
PATH_MAPPINGS=/data:/media;/data/anime:/mnt/anime-ssd
```

Notes:

- Matching is on path segments. `/data/tv` will never match `/data/tv-4k`.
- Trailing slashes are insignificant.
- An unmapped path is used as-is, so a mapping is only needed where views differ.
- A malformed entry is discarded rather than failing startup.

If a library's root does not resolve to a readable directory after mapping,
Fanfarr reports it rather than silently doing nothing. A local theme mode that
quietly writes nowhere is the worst possible failure here.

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

## Read-only mounts

The library mount cannot be read-only if you use local theme output -- that
mode writes into it. If you use API-upload mode exclusively, a read-only mount
is fine and is a reasonable precaution.
