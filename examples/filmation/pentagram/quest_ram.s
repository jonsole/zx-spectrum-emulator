; ---------------------------------------------------------------------------
; The quest's working tables, kept in the room builder's page, where there is
; room: the main page has almost none left.
;
; quest_table   the eighteen records, as this game has them -- see quest.s
; rooms_seen    a bit for every room he has been in -- see gameover.s
; ---------------------------------------------------------------------------

quest_table:        DS      QUEST_RECORDS * QR_LEN
rooms_seen:         DS      32
