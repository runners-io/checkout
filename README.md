# checkout

[`actions/checkout`](https://github.com/actions/checkout) for [runners.io](https://www.runners.io)
runners, served from a git mirror kept on the repository's sticky disk.

```yaml
- uses: runners-io/checkout@v1
```

It is a drop-in for `actions/checkout`: every input is forwarded. When the job
has a sticky disk, it keeps a bare mirror of the repository on that disk and
checks out from it, fetching only what the repository gained since the last
job. When it cannot use the mirror (no sticky disk, a fork, submodules, LFS,
sparse or filtered checkouts, an SSH key, a damaged mirror) it runs the
upstream action unchanged and says why in one line. A mirror problem costs
speed, never the checkout.

Documentation: https://www.runners.io/docs/caching/git-checkout-cache

Inputs and behaviour are described in [`action.yml`](action.yml). The source of
this repository lives in runners.io's own repository and is published here.
