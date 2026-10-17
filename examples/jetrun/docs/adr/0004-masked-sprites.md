# Masked sprites

Cyberun draws its objects with no mask: the old picture is rubbed out and the
new one ORed onto whatever is there, so a sprite over rock merges with the
checker. Jetrun's astronaut walks on slopes and carries things into caverns,
so sprites overlap rock all the time, and they are drawn with masks -- a black
outline round each figure -- at about twice the cost per sprite. Since the
screen is never cleared, what lies under a sprite is saved before it is drawn
and put back before the next pass's landscape.
