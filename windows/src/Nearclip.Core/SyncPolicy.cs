namespace Nearclip.Core;

public sealed record SyncPolicy(bool Send = true, bool Receive = true, bool Images = true, bool Codes = true)
{
    public bool Permits(Clip c, bool sending) => (sending ? Send : Receive) && (!c.IsImage || Images) && (!c.IsCode || Codes);
}
