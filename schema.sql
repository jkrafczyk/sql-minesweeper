PRAGMA recursive_triggers = ON;
DROP TABLE IF EXISTS games;
DROP TABLE IF EXISTS bombs;
DROP TABLE IF EXISTS clicks;
DROP TABLE IF EXISTS flags;

--- Storage and game status:
CREATE TABLE games(
    name VARCHAR NOT NULL PRIMARY KEY,
    status VARCHAR NOT NULL,
    rows INTEGER NOT NULL,
    columns INTEGER NOT NULL,
    bombs INTEGER NOT NULL
);

CREATE TABLE bombs(
    game_name VARCHAR NOT NULL REFERENCES games(name),
    row INTEGER NOT NULL,
    "column" INTEGER NOT NULL,
    unique (game_name, row, "column")
);

CREATE TABLE clicks(
    game_name VARCHAR NOT NULL REFERENCES games(name),
    row INTEGER NOT NULL,
    "column" INTEGER NOT NULL,
    unique (game_name, row, "column")
);

CREATE TABLE flags(
    game_name VARCHAR NOT NULL REFERENCES games(name),
    row INTEGER NOT NULL,
    "column" INTEGER NOT NULL,
    unique (game_name, row, "column")
);


--- Output

--Returns all valid row numbers for each game:
DROP VIEW IF EXISTS board_rows;
CREATE VIEW board_rows(game_name, row_number) AS
WITH RECURSIVE
    rows AS (
        SELECT game.name game_name, 1 num, game.rows maxrows  FROM games game
        UNION ALL
        SELECT r2.game_name, r2.num + 1, r2.maxrows FROM rows r2 WHERE r2.num  < r2.maxrows
    )
    SELECT game_name, num FROM rows
    ;

--Returns all valid column numbers for each game:
DROP VIEW IF EXISTS board_columns;
CREATE VIEW board_columns(game_name, column_number) AS
WITH RECURSIVE
    columns AS (
        SELECT game.name game_name, 1 num, game.columns maxcols  FROM games game
        UNION ALL
        SELECT c2.game_name, c2.num + 1, c2.maxcols FROM columns c2 WHERE c2.num  < c2.maxcols
    )
    SELECT game_name, num FROM columns
    ;

--Returns all cells including any relevant status and an appropriate character for displaying the cell for each game:
DROP VIEW IF EXISTS board_cells;
CREATE VIEW board_cells(game_name, row, "column", clicked, flagged, is_bomb, bomb_neighbours, visible, rendered, cheat_rendered) AS
WITH
    --All row/column coordinates for all games:
    cells AS (
        SELECT
            row.game_name,
            row.row_number,
            col.column_number
        FROM board_rows row
            INNER JOIN board_columns col ON row.game_name = col.game_name
    ),
    -- abstract information (visiblity, clicked, flagged, bomb, etc) for each cell:
    cellinfo AS (SELECT
           cell.game_name game_name,
           cell.row_number row_number,
           cell.column_number column_number,
           CASE WHEN EXISTS(SELECT * FROM clicks WHERE game_name = cell.game_name AND row = cell.row_number AND "column" = cell.column_number) THEN 1 else 0 END clicked,
           CASE WHEN EXISTS(SELECT * FROM flags WHERE game_name = cell.game_name AND row = cell.row_number AND "column" = cell.column_number) THEN 1 else 0 END flagged,
           CASE WHEN EXISTS(SELECT * FROM bombs WHERE game_name = cell.game_name AND row = cell.row_number AND "column" = cell.column_number) THEN 1 else 0 END is_bomb,
           (SELECT COUNT(*) FROM bombs b
                    WHERE b.game_name = cell.game_name
                      AND b.row >= cell.row_number - 1 AND b.row <= cell.row_number + 1
                      AND b.column >= cell.column_number - 1 AND b.column <= cell.column_number + 1
                      AND (b.row != cell.row_number OR b.column != cell.column_number)) bomb_neighbours,
           CASE WHEN EXISTS(
               SELECT * FROM clicks c
               WHERE c.game_name = cell.game_name
               AND c.row >= cell.row_number - 1 AND c.row <= row_number + 1
               AND c.column >= cell.column_number - 1 AND c.column <= cell.column_number + 1
           ) THEN 1 ELSE 0 END visible
    FROM cells cell)
    --Cellinfo, but with display values for the cell
    SELECT
           *,
           --Display for in-game board:
           CASE
                --clicked bomb after end of game
                WHEN is_bomb > 0 AND EXISTS(SELECT * FROM games WHERE name = game_name AND status != 'ACTIVE') AND EXISTS(SELECT * FROM clicks WHERE game_name = cellinfo.game_name AND row = cellinfo.row_number AND "column" = cellinfo.column_number) THEN '!'
               --non-clicked bomb after end of game
                WHEN is_bomb > 0 AND EXISTS(SELECT * FROM games WHERE name = game_name AND status != 'ACTIVE') THEN '*'
                WHEN bomb_neighbours > 0 AND clicked > 0 THEN bomb_neighbours
                WHEN clicked > 0 THEN '█'
                --incorrectly flagged field after end of game
                WHEN flagged > 0 AND EXISTS(SELECT * FROM games WHERE name = game_name AND status != 'ACTIVE') AND NOT EXISTS(SELECT * FROM clicks WHERE game_name = cellinfo.game_name AND row = cellinfo.row_number AND "column" = cellinfo.column_number) then 'ꟻ'
                WHEN flagged > 0 THEN 'F'
                ELSE ' '
           END rendered,
           --Display for cheat view
           CASE
               WHEN is_bomb > 0 THEN '*'
               WHEN bomb_neighbours > 0 THEN bomb_neighbours
               WHEN flagged > 0 THEN 'F'
               WHEN clicked > 0 THEN '█'
               ELSE ' '
           END cheat_rendered
    FROM cellinfo
;

--Partially rendered boards for all games:
-- (one result row for each row of the board)
DROP VIEW IF EXISTS rendered_board;
CREATE VIEW rendered_board(game_name, row_number, rendered) AS
WITH RECURSIVE
    output AS (
        SELECT
               game_name game_name,
               row_number row_number,
               '' rendered,
               0 is_last
        FROM board_rows rows
        UNION ALL
        SELECT
            game_name,
            row_number,
            rendered || (SELECT rendered FROM board_cells cell WHERE cell.game_name = output.game_name AND cell.row = output.row_number AND cell.column = LENGTH(output.rendered) + 1),
            LENGTH(rendered) = (SELECT columns FROM games game WHERE game.name = output.game_name) - 1
        FROM output WHERE is_last = 0
    )
SELECT game_name, row_number, rendered FROM output WHERE is_last = 1;

--Partially rendered boards for all games, for cheating (shows bombs before game is over):
-- (one result row for each row of the board)
DROP VIEW IF EXISTS cheat_board;
CREATE VIEW cheat_board(game_name, row_number, rendered) AS
WITH RECURSIVE
    output AS (
        SELECT
               game_name game_name,
               row_number row_number,
               '' rendered,
               0 is_last
        FROM board_rows rows
        UNION ALL
        SELECT
            game_name,
            row_number,
            rendered || (SELECT cheat_rendered FROM board_cells cell WHERE cell.game_name = output.game_name AND cell.row = output.row_number AND cell.column = LENGTH(output.rendered) + 1),
            LENGTH(rendered) = (SELECT columns FROM games game WHERE game.name = output.game_name) - 1
        FROM output WHERE is_last = 0
    )
SELECT game_name, row_number, rendered FROM output WHERE is_last = 1;

-- 'User-friendly' prompt including a full ascii-art rendered board, some instructions and information about the game status
DROP VIEW IF EXISTS game_prompt;
DROP VIEW IF EXISTS current_game_prompt;
CREATE VIEW game_prompt(game_name, output) AS
WITH RECURSIVE
    board AS (
        SELECT
               game_name game_name,
               '' rendered,
               0 row_number,
               (SELECT rows FROM games WHERE name = game_name) num_rows,
               0 is_last
        FROM
             rendered_board
        WHERE row_number = 1
        UNION ALL
        SELECT
            board.game_name,
            board.rendered || COALESCE((SELECT '|' || rendered || '|' FROM rendered_board WHERE rendered_board.row_number = board.row_number + 1), '') || x'0a',
            board.row_number + 1,
            board.num_rows,
            board.row_number + 1 = board.num_rows
        FROM board WHERE is_last = 0
    ),
    game_status_msg AS (
        SELECT
               name game_name,
               'Playing "' || name || '" on ' || rows || 'x' || columns || ' board' title,
               CASE
                   WHEN status = 'ACTIVE' THEN 'Game in progress'
                   WHEN status = 'WON' THEN 'Game won'
                   WHEN status = 'LOST' THEN 'Game lost'
               END status_message,
               CASE
                   WHEN status = 'ACTIVE' THEN 'Please choose your next move by INSERTing into click_cell'
                   ELSE ''
               END prompt
        FROM games
    )
SELECT
       board.game_name,
       game_status_msg.title || x'0a' || game_status_msg.status_message || x'0a' || board.rendered || game_status_msg.prompt || x'0a'
       FROM board
       INNER JOIN game_status_msg ON board.game_name = game_status_msg.game_name
       INNER JOIN games ON board.game_name = games.name
       WHERE board.is_last = 1
       ORDER BY games.ROWID DESC
       ;

--- Input
DROP VIEW IF EXISTS start_game;
DROP VIEW IF EXISTS click_cell;
DROP VIEW IF EXISTS click_cell_on_game;
CREATE VIEW start_game(name, rows, columns, bombs) AS SELECT(NULL, NULL, NULL, NULL);

CREATE TRIGGER start_game
    INSTEAD OF INSERT ON start_game
    BEGIN
        SELECT RAISE(FAIL, 'Board too small') WHERE COALESCE(NEW.rows, 10) < 4 OR COALESCE(NEW.columns, 10) < 4;
        SELECT RAISE(FAIL, 'Board too small for selected number of bombs') WHERE COALESCE(NEW.bombs, 10) > (COALESCE(NEW.rows, 10) * COALESCE(NEW.columns, 10) - 10);

        --Ensure only one game is running at any time.
        SELECT RAISE(FAIL, 'Game already running.') FROM games WHERE status = 'ACTIVE';

        --Create game
        INSERT INTO
            games(name, status, rows, columns, bombs)
        VALUES (NEW.name,
                'ACTIVE',
                COALESCE(NEW.rows, 10),
                COALESCE(NEW.columns, 10),
                COALESCE(NEW.bombs, 10)
            );
    END;

DROP VIEW IF EXISTS random_locations;
CREATE VIEW random_locations(game_name, row, "column") AS
WITH RECURSIVE
     loc AS (
         SELECT
                g.name game_name,
                1 + ABS(RANDOM()) % (SELECT rows FROM games WHERE name = g.name) row,
                1 + ABS(RANDOM()) % (SELECT columns FROM games WHERE name = g.name) col
         FROM games g
         UNION ALL
         SELECT
                loc.game_name,
                1 + ABS(RANDOM()) % (SELECT rows FROM games WHERE name = loc.game_name) row,
                1 + ABS(RANDOM()) % (SELECT columns FROM games WHERE name = loc.game_name) col
         FROM loc
     )
SELECT DISTINCT * FROM loc;

DROP VIEW IF EXISTS random_free_locations;
CREATE VIEW random_free_locations(game_name, row, "column") AS
    SELECT * FROM random_locations loc
    WHERE NOT EXISTS(SELECT * FROM bombs b WHERE b.game_name = loc.game_name AND b.row = loc.row AND b.column = loc.column)
    AND NOT EXISTS(SELECT * FROM clicks c WHERE c.game_name = loc.game_name AND c.row = loc.row AND c.column = loc.column);


DROP VIEW IF EXISTS suitable_bomb_locations;
CREATE VIEW suitable_bomb_locations(game_name, row, "column") AS
WITH neighbours_of_clicks AS (
    SELECT game_name, row, "column" FROM board_cells WHERE visible > 0
)
SELECT * FROM random_free_locations loc
    WHERE NOT EXISTS(SELECT * FROM neighbours_of_clicks nb WHERE loc.row = nb.row AND loc."column" = nb."column" AND loc.game_name = nb.game_name);


DROP VIEW IF EXISTS flag_cell_on_game;
CREATE VIEW flag_cell_on_game(game_name, row, "column") AS SELECT(NULL, NULL, NULL);
CREATE TRIGGER flag_cell_on_game INSTEAD OF INSERT ON flag_cell_on_game
BEGIN
    INSERT INTO flags(game_name, row, "column") VALUES (NEW.game_name, NEW.row, NEW."column") ON CONFLICT DO NOTHING;
END;

DROP VIEW IF EXISTS unflag_cell_on_game;
CREATE VIEW unflag_cell_on_game(game_name, row, "column") AS SELECT(NULL, NULL, NULL);
CREATE TRIGGER unflag_cell_on_game INSTEAD OF INSERT ON unflag_cell_on_game
BEGIN
    DELETE FROM flags WHERE flags.game_name = NEW.game_name AND flags.row = NEW.row AND flags."column" = NEW."column";
END;

CREATE VIEW click_cell_on_game(game_name, row, "column") AS SELECT(NULL, NULL, NULL);
CREATE TRIGGER click_cell_on_game INSTEAD OF INSERT ON click_cell_on_game
BEGIN
    --Check if game exists and is still running:
    SELECT RAISE(FAIL, 'Game not found') WHERE NOT EXISTS(SELECT * FROM games WHERE name = NEW.game_name);
    SELECT RAISE(FAIL, 'Game already finished') FROM games WHERE name = NEW.game_name AND status != 'ACTIVE';

    --Check if field was already clicked:
    SELECT RAISE(IGNORE) FROM clicks WHERE game_name = NEW.game_name AND row = NEW.row AND "column" = NEW."column";

    --Do not click flagged cells:
    SELECT RAISE(IGNORE) FROM flags WHERE game_name = NEW.game_name AND row = NEW.row AND "column" = NEW."column";

    --Check if field is in range of valid fields for board:
    SELECT RAISE(FAIL, 'Selected position is of of bounds')
        WHERE NEW.row <= 0 OR new.column <= 0
        OR NEW.row > (SELECT rows FROM games WHERE name = NEW.game_name)
        OR NEW.column > (SELECT columns FROM games WHERE name = NEW.game_name);

    --Save 'click'
    INSERT INTO clicks(game_name, row, "column") VALUES (NEW.game_name, NEW.row, NEW.column);

    --Check loss condition:
    UPDATE games SET status = 'LOST'
    WHERE name = NEW.game_name
      AND EXISTS(SELECT * FROM bombs WHERE bombs.game_name = NEW.game_name AND bombs.row = NEW.row AND bombs.column = NEW.column);
    SELECT RAISE(FAIL, 'Bomb clicked!') FROM games WHERE name = NEW.game_name AND status != 'ACTIVE';


    --Generate missing bombs, if necessary
    INSERT INTO bombs(game_name, row, "column")
        SELECT * FROM suitable_bomb_locations
        LIMIT
            (SELECT bombs FROM games WHERE name = NEW.game_name) - (SELECT COUNT(*) FROM bombs WHERE game_name = NEW.game_name);

    --Unflag all cells that we will auto-click in the next step:
    INSERT INTO unflag_cell_on_game(game_name, row, "column")
    SELECT
           NEW.game_name,
           c.row,
           c.column
    FROM board_cells c
    WHERE
          c.game_name = NEW.game_name
    AND   c.row >= NEW.row - 1 AND c.row <= NEW.row + 1
    AND   c.column >= NEW.column -1 AND c.column <= NEW.column + 1
    AND   (SELECT board_cells.bomb_neighbours
           FROM board_cells
           WHERE game_name = NEW.game_name
           AND   "row" = NEW.row
           AND "column" = NEW.column) = 0;
    --If the clicked cell does not have mines as neighbours, click all neighbours.
    INSERT INTO click_cell_on_game(game_name, row, "column")
    SELECT
           NEW.game_name,
           c.row,
           c.column
    FROM board_cells c
    WHERE
          c.game_name = NEW.game_name
    AND   c.row >= NEW.row - 1 AND c.row <= NEW.row + 1
    AND   c.column >= NEW.column -1 AND c.column <= NEW.column + 1
    AND   (SELECT board_cells.bomb_neighbours
           FROM board_cells
           WHERE game_name = NEW.game_name
           AND   "row" = NEW.row
           AND "column" = NEW.column) = 0;

    --Check win condition: (All non-mines clicked)
    UPDATE games SET status = 'WON' WHERE name = NEW.game_name AND NOT EXISTS(
        SELECT * FROM board_cells
        WHERE
              game_name = NEW.game_name
          AND is_bomb = 0 AND clicked = 0
    );
END;

CREATE VIEW click_cell(row, "column") AS SELECT(NULL, NULL);
CREATE TRIGGER click_cell INSTEAD OF INSERT ON click_cell
BEGIN
    SELECT RAISE(FAIL, 'Game not running.') WHERE NOT EXISTS(SELECT * FROM games WHERE status = 'ACTIVE');
    INSERT INTO click_cell_on_game(game_name,
                                   row,
                                   "column")
    VALUES (
            (SELECT name FROM games WHERE status = 'ACTIVE'),
            NEW.row,
            NEW."column"
           );
END;

CREATE VIEW flag_cell(row, "column") AS SELECT(NULL, NULL);
CREATE TRIGGER flag_cell INSTEAD OF INSERT ON flag_cell
BEGIN
    SELECT RAISE(FAIL, 'Game not running.') WHERE NOT EXISTS(SELECT * FROM games WHERE status = 'ACTIVE');
    INSERT INTO flag_cell_on_game(game_name,
                                   row,
                                   "column")
    VALUES (
            (SELECT name FROM games WHERE status = 'ACTIVE'),
            NEW.row,
            NEW."column"
           );
END;

CREATE VIEW unflag_cell(row, "column") AS SELECT(NULL, NULL);
CREATE TRIGGER unflag_cell INSTEAD OF INSERT ON unflag_cell
BEGIN
    SELECT RAISE(FAIL, 'Game not running.') WHERE NOT EXISTS(SELECT * FROM games WHERE status = 'ACTIVE');
    INSERT INTO unflag_cell_on_game(game_name,
                                   row,
                                   "column")
    VALUES (
            (SELECT name FROM games WHERE status = 'ACTIVE'),
            NEW.row,
            NEW."column"
           );
END;