# Module: cloudflare-dns

Zone records for the API, the CMS and the share-link host. Implements INF-011.

DNS drift is a deployment hazard: a record edited in the dashboard disappears on the next
apply, or worse, silently keeps traffic pointed at a decommissioned host. Every record lives
here and changes through a pull request.

`go.gogo.id.vn` is the canonical share-link host (`GOGO_SRS.md` §8.11). The Worker route that
serves `/l/{slug}` and the `.well-known` association files is INF-012 and is added on top of
this record once `LNK-BE-002` exposes the resolve API.

## Usage

```hcl
module "dns" {
  source  = "../../modules/cloudflare-dns"
  zone_id = var.cloudflare_zone_id

  records = {
    api = {
      name    = "api.gogo.id.vn"
      type    = "A"
      content = var.vps_ipv4
    }
    share = {
      name    = "go.gogo.id.vn"
      type    = "A"
      content = var.vps_ipv4
    }
  }
}
```
