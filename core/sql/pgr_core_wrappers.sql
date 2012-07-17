--
-- Copyright (c) 2005 Sylvain Pasche,
--               2006-2007 Anton A. Patrushev
--               2012 Mario Basa
--
-- This program is free software; you can redistribute it and/or modify
-- it under the terms of the GNU General Public License as published by
-- the Free Software Foundation; either version 2 of the License, or
-- (at your option) any later version.
--
-- This program is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
-- GNU General Public License for more details.
--
-- You should have received a copy of the GNU General Public License
-- along with this program; if not, write to the Free Software
-- Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA 02111-1307, USA.

CREATE OR REPLACE FUNCTION pgr_startpoint(line geometry)
    returns geometry as
$body$
DECLARE
    pnt geometry;
BEGIN
	
 if st_geometrytype(line) = 'ST_LineString' then
     pnt := st_startpoint(line);
 elsif st_geometrytype(line) = 'ST_MultiLineString' then
   pnt := st_startpoint(st_geometryn(line,1));
 else
   return null;
 end if;
 
 return pnt;

 END;
$body$
LANGUAGE 'plpgsql' STABLE;

CREATE OR REPLACE FUNCTION pgr_endpoint(line geometry)
    returns geometry as
$body$
DECLARE
    pnt geometry;
BEGIN

 if st_geometrytype(line) = 'ST_LineString' then
     pnt := st_endpoint(line);
 elsif st_geometrytype(line) = 'ST_MultiLineString' then
   pnt := st_endpoint(st_geometryn(line,1));
 else
   return null;
 end if;
 
 return pnt;

END;
$body$
LANGUAGE 'plpgsql' STABLE;

-----------------------------------------------------------------------
-- Dijkstra wrapper function for directed graphs.
-- Compute the shortest path using edges table, and return
-- the result as a set of (gid integer, the_geom geometry) records.
-- 
-- Parameters: geom_table  : Table Name
--             source      : Source ID
--             target      : Target ID
--             cost        : Cost Column
--             dir         : Directed Search  (true/false)
--             rc          : Has Reverse Cost (true/false)
--
-- Last changes: July 1, 2012
-----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pgr_dijkstra_sp(
       geom_table varchar, source int4, target int4, 
       cost varchar, dir boolean, rc boolean) 
       RETURNS SETOF GEOMS AS
$$
DECLARE 
    path_result record;

    geom geoms;
    query text;
    
    id integer;
BEGIN
    
    id :=0;
    
    query := 'SELECT id,the_geom FROM ' ||
             'shortest_path(''SELECT id, source::integer, ' || 
             'target::integer,'||cost||'::double precision as cost ';
      
    IF rc THEN 
       query := query || ', reverse_cost ';  
    END IF;
    
    query := query || 'FROM ' ||  quote_ident(geom_table) || ''', ' || 
             quote_literal(source) || ' , ' || 
             quote_literal(target) || ' , '''||
             text(dir)||''', '''||text(rc)||'''), ' || 
             quote_ident(geom_table) || ' where edge_id = id ';

    FOR path_result IN EXECUTE query
        LOOP

          geom.gid      := path_result.id;
          geom.the_geom := path_result.the_geom;
          id            := id+1;
          geom.id       := id;
                 
          RETURN NEXT geom;

    END LOOP;
    RETURN;
END;
$$
LANGUAGE 'plpgsql' VOLATILE STRICT; 

-----------------------------------------------------------------------
-- Dijkstra wrapper function for directed graphs.
-- Compute the shortest path using edges table, and return
-- the result as a set of (gid integer, the_geom geometry) records.
-- 
-- Parameters: geom_table  : Table Name
--             sourcept    : Source XY (i.e. 'POINT(135 35)' )
--             targetpt    : Target XY (i.e. 'POINT(136 36)' )
--             cost        : Cost Column
--             delta       : clipping boundary offset in map units
--             dir         : Directed Search  (true/false)
--             rc          : Has Reverse Cost (true/false)
--
-- Last changes: July 1, 2012
-----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pgr_dijkstra_sp(
       geom_table varchar, sourcept varchar, targetpt varchar, 
       cost varchar, delta float8, dir boolean, rc boolean) 
       RETURNS SETOF GEOMS AS
$$
DECLARE 
    path_result record;
    rec         record;
    
    geom  geoms;
    query text;
    
    id       integer;
    sourceid integer;
    targetid integer;
BEGIN
    
    id :=0;
    
    FOR rec IN EXECUTE
            'select find_nearest_node_within_distance(''' ||
            sourcept || ''','|| delta || ',''' || geom_table || ''')' ||
            ' as sourceid'
         LOOP
    END LOOP;
    
    IF rec IS NULL THEN
        RETURN;
    END IF;
    
    sourceid := rec.sourceid;
    
    FOR rec IN EXECUTE
            'select find_nearest_node_within_distance(''' ||
            targetpt || ''','|| delta || ',''' || geom_table || ''')' ||
            ' as targetid'
         LOOP
    END LOOP;
    
    IF rec IS NULL THEN
        RETURN;
    END IF;
    
    targetid := rec.targetid;
    
    query := 'select * from pgr_dijkstra_sp('''||geom_table||''','||
        sourceid||','||targetid||','''||cost||''','||dir||','||rc||')'; 
    
    FOR path_result IN EXECUTE query
        LOOP

          geom.gid      := path_result.id;
          geom.the_geom := path_result.the_geom;
          id            := id+1;
          geom.id       := id;
                 
          RETURN NEXT geom;

    END LOOP;
    RETURN;
END;
$$
LANGUAGE 'plpgsql' VOLATILE STRICT; 


-----------------------------------------------------------------------
-- Dijkstra function for directed graphs.
-- Compute the shortest path using edges table, and return
-- the result as a set of (gid integer, the_geom geometry) records.
-- Also data clipping added to improve function performance.
--
-- Parameters: geom_table  : Table Name
--             sourceid    : Source Edge ID
--             targetid    : Target Edge ID
--             cost        : Cost Column
--             delta       : clipping boundary offset in map units
--             dir         : Directed Search  (true/false)
--             rc          : Has Reverse Cost (true/false)
--
-- Last changes: July 1, 2012
-----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pgr_dijkstra_sp_clip(
       geom_table varchar, sourceid int4, targetid int4, 
       cost varchar, delta float8, dir boolean, rc boolean) 
       RETURNS SETOF GEOMS AS
$$
DECLARE 
    rec         record;
    path_result record;
    
    id   integer;
    v_id integer;
    e_id integer;
    srid integer;
    
    geom geoms;
    
    source_x float8;
    source_y float8;
    target_x float8;
    target_y float8;
    
    ll_x float8;
    ll_y float8;
    ur_x float8;
    ur_y float8;
    
    query text;
    
BEGIN
    
    id :=0;
    FOR rec IN EXECUTE
        'select st_srid(the_geom) as srid from ' ||
        quote_ident(geom_table) || ' limit 1'
    LOOP
    END LOOP;
    
    srid := rec.srid;

    FOR rec IN EXECUTE 
            'select st_x(pgr_startpoint(the_geom)) as source_x from ' || 
            quote_ident(geom_table) || ' where source = ' || 
            sourceid ||  ' or target='||sourceid||' limit 1'
        LOOP
    END LOOP;
    
    source_x := rec.source_x;
    
    FOR rec IN EXECUTE 
            'select st_y(pgr_startpoint(the_geom)) as source_y from ' || 
            quote_ident(geom_table) || ' where source = ' || 
            sourceid ||  ' or target='||sourceid||' limit 1'
        LOOP
    END LOOP;

    source_y := rec.source_y;

    FOR rec IN EXECUTE 
            'select st_x(pgr_startpoint(the_geom)) as target_x from ' ||
            quote_ident(geom_table) || ' where source = ' || 
            targetid ||  ' or target='||targetid||' limit 1'
        LOOP
    END LOOP;

    target_x := rec.target_x;
    
    FOR rec IN EXECUTE 
            'select st_y(pgr_startpoint(the_geom)) as target_y from ' || 
            quote_ident(geom_table) || ' where source = ' || 
            targetid ||  ' or target='||targetid||' limit 1'
        LOOP
    END LOOP;
    
    target_y := rec.target_y;

    FOR rec IN EXECUTE 'SELECT CASE WHEN '||source_x||'<'||target_x||
           ' THEN '||source_x||' ELSE '||target_x||
           ' END as ll_x, CASE WHEN '||source_x||'>'||target_x||
           ' THEN '||source_x||' ELSE '||target_x||' END as ur_x'
        LOOP
    END LOOP;

    ll_x := rec.ll_x;
    ur_x := rec.ur_x;

    FOR rec IN EXECUTE 'SELECT CASE WHEN '||source_y||'<'||
            target_y||' THEN '||source_y||' ELSE '||
            target_y||' END as ll_y, CASE WHEN '||
            source_y||'>'||target_y||' THEN '||
            source_y||' ELSE '||target_y||' END as ur_y'
        LOOP
    END LOOP;

    ll_y := rec.ll_y;
    ur_y := rec.ur_y;

    query := 'SELECT id,the_geom FROM ' || 
          'shortest_path(''SELECT id as id, ' || 
          'source::integer, target::integer, ' || cost || 
          '::double precision as cost ';
      
    IF rc THEN query := query || ' , reverse_cost ';
    END IF;

    query := query || ' FROM ' || quote_ident(geom_table) || 
          ' where st_setSRID(''''BOX3D(' ||
          ll_x-delta||' '|| ll_y-delta ||',' ||
          ur_x+delta||' '|| ur_y+delta ||')''''::BOX3D, ' || 
          srid || ') && the_geom'', ' || 
          quote_literal(sourceid) || ' , ' || 
          quote_literal(targetid) || ' , '''||
          text(dir)||''', '''||
          text(rc )||''' ), ' ||
          quote_ident(geom_table) || ' where edge_id = id ';
      
    FOR path_result IN EXECUTE query
        LOOP
                 
        geom.gid      := path_result.id;
        geom.the_geom := path_result.the_geom;
        id            := id+1;
        geom.id       := id;
                 
        RETURN NEXT geom;

    END LOOP;
    RETURN;
    
END;
$$
LANGUAGE 'plpgsql' VOLATILE STRICT; 

-----------------------------------------------------------------------
-- Dijkstra function for directed graphs.
-- Compute the shortest path using edges table, and return
-- the result as a set of (gid integer, the_geom geometry) records.
-- Also data clipping added to improve function performance.
--
-- Parameters: geom_table  : Table Name
--             sourcept    : Source XY (i.e. 'POINT(135 35)' )
--             targetpt    : Target XY (i.e. 'POINT(136 36)' )
--             cost        : Cost Column
--             delta       : search boundary offset in map units
--             dir         : Directed Search  (true/false)
--             rc          : Has Reverse Cost (true/false)
--
-- Last changes: July 1, 2012
-----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pgr_dijkstra_sp_clip(
       geom_table varchar, sourcept varchar, targetpt varchar, 
       cost varchar, delta float8, dir boolean, rc boolean) 
       RETURNS SETOF GEOMS AS
$$
DECLARE 
    rec         record;
    path_result record;
    
    id       integer;
    sourceid integer;
    targetid integer;
    
    geom  geoms;    
    query text;
    
BEGIN
    
    id :=0;

    FOR rec IN EXECUTE
            'select find_nearest_node_within_distance(''' ||
            sourcept || ''','|| delta || ',''' || geom_table || ''')' ||
            ' as sourceid'
         LOOP
    END LOOP;
    
    IF rec IS NULL THEN
        RETURN;
    END IF;
    
    sourceid := rec.sourceid;
    
    FOR rec IN EXECUTE
            'select find_nearest_node_within_distance(''' ||
            targetpt || ''','|| delta || ',''' || geom_table || ''')' ||
            ' as targetid'
         LOOP
    END LOOP;
    
    IF rec IS NULL THEN
        RETURN;
    END IF;
    
    targetid := rec.targetid;

    query := 'select * from pgr_dijkstra_sp_clip('''||geom_table||''','||
        sourceid||','||targetid||','''||cost||''','||delta||','||
        dir||','||rc||')';
        
    FOR path_result IN EXECUTE query
        LOOP
                 
        geom.gid      := path_result.id;
        geom.the_geom := path_result.the_geom;
        id            := id+1;
        geom.id       := id;
                 
        RETURN NEXT geom;

    END LOOP;
    RETURN;
    
END;
$$
LANGUAGE 'plpgsql' VOLATILE STRICT; 


-----------------------------------------------------------------------
-- A-Star wrapper function for directed graphs.
-- Compute the shortest path using edges table, and return
-- the result as a set of (gid integer, the_geom geometry) records.
-- 
-- Parameters: geom_table  : Table Name
--             source      : Source ID
--             target      : Target ID
--             cost        : Cost Column
--             dir         : Directed Search  (true/false)
--             rc          : Has Reverse Cost (true/false)
--
-- Last changes: July 1, 2012
-----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pgr_astar_sp(
       geom_table varchar, source int4, target int4, 
       cost float8, dir boolean, rc boolean)
       RETURNS SETOF GEOMS AS
$$
DECLARE 
    path_result record;

    geom geoms;
    query text;
    
    id integer;
BEGIN
    
    id :=0;
    
    query := 'SELECT id,the_geom FROM ' ||
             'shortest_path_astar(''SELECT id,x1,y1,x2,y2,'||
             'source::integer, target::integer,'||
             cost||'::double precision as cost ';
      
    IF rc THEN 
       query := query || ', reverse_cost ';  
    END IF;
    
    query := query || 'FROM ' ||  quote_ident(geom_table) || ''', ' || 
             quote_literal(source) || ' , ' || 
             quote_literal(target) || ' , '''||
             text(dir)||''', '''||text(rc)||'''), ' || 
             quote_ident(geom_table) || ' where edge_id = id ';

    FOR path_result IN EXECUTE query
        LOOP

          geom.gid      := path_result.id;
          geom.the_geom := path_result.the_geom;
          id            := id+1;
          geom.id       := id;
                 
          RETURN NEXT geom;

    END LOOP;
    RETURN;
END;
$$
LANGUAGE 'plpgsql' VOLATILE STRICT; 


-----------------------------------------------------------------------
-- A-Star wrapper function for directed graphs.
-- Compute the shortest path using edges table, and return
-- the result as a set of (gid integer, the_geom geometry) records.
-- 
-- Parameters: geom_table  : Table Name
--             sourcept    : Source XY (i.e. 'POINT(135 35)' )
--             targetpt    : Target XY (i.e. 'POINT(136 36)' )
--             cost        : Cost Column
--             delta       : clipping boundary offset in map units
--             dir         : Directed Search  (true/false)
--             rc          : Has Reverse Cost (true/false)
--
-- Last changes: July 1, 2012
-----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pgr_astar_sp(
       geom_table varchar, sourcept varchar, targetpt varchar, 
       cost varchar, delta float8, dir boolean, rc boolean) 
       RETURNS SETOF GEOMS AS
$$
DECLARE 
    path_result record;
    rec         record;
    
    geom  geoms;
    query text;
    
    id       integer;
    sourceid integer;
    targetid integer;
BEGIN
    
    id :=0;
    
    FOR rec IN EXECUTE
            'select find_nearest_node_within_distance(''' ||
            sourcept || ''','|| delta || ',''' || geom_table || ''')' ||
            ' as sourceid'
         LOOP
    END LOOP;
    
    IF rec IS NULL THEN
        RETURN;
    END IF;
    
    sourceid := rec.sourceid;
    
    FOR rec IN EXECUTE
            'select find_nearest_node_within_distance(''' ||
            targetpt || ''','|| delta || ',''' || geom_table || ''')' ||
            ' as targetid'
         LOOP
    END LOOP;
    
    IF rec IS NULL THEN
        RETURN;
    END IF;
    
    targetid := rec.targetid;
    
    query := 'select * from pgr_astar_sp('''||geom_table||''','||
        sourceid||','||targetid||','''||cost||''','||dir||','||rc||')'; 
    
    FOR path_result IN EXECUTE query
        LOOP

          geom.gid      := path_result.id;
          geom.the_geom := path_result.the_geom;
          id            := id+1;
          geom.id       := id;
                 
          RETURN NEXT geom;

    END LOOP;
    RETURN;
END;
$$
LANGUAGE 'plpgsql' VOLATILE STRICT; 

-----------------------------------------------------------------------
-- A-Star function for directed graphs.
-- Compute the shortest path using edges table, and return
-- the result as a set of (gid integer, the_geom geometry) records.
-- Also data clipping added to improve function performance.
--
-- Parameters: geom_table  : Table Name
--             sourceid    : Source Edge ID
--             targetid    : Target Edge ID
--             cost        : Cost Column
--             delta       : clipping boundary offset in map units
--             dir         : Directed Search  (true/false)
--             rc          : Has Reverse Cost (true/false)
--
-- Last changes: July 1, 2012
-----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pgr_astar_sp_clip(
       geom_table varchar, sourceid int4, targetid int4, 
       cost varchar, delta float8, dir boolean, rc boolean) 
       RETURNS SETOF GEOMS AS
$$
DECLARE 
    rec         record;
    path_result record;
    
    v_id integer;
    e_id integer;
    srid integer;
    
    geom geoms;
    
    source_x float8;
    source_y float8;
    target_x float8;
    target_y float8;
    
    ll_x float8;
    ll_y float8;
    ur_x float8;
    ur_y float8;
    
    query text;

    id integer;
BEGIN
    
    id :=0;
    FOR rec IN EXECUTE
        'select st_srid(the_geom) as srid from ' ||
        quote_ident(geom_table) || ' limit 1'
    LOOP
    END LOOP;
    srid := rec.srid;
    
    FOR rec IN EXECUTE 
            'select st_x(pgr_startpoint(the_geom)) as source_x from ' || 
            quote_ident(geom_table) || ' where source = ' || 
            sourceid || ' or target='||sourceid||' limit 1'
        LOOP
    END LOOP;
    source_x := rec.source_x;
    
    FOR rec IN EXECUTE 
            'select st_y(pgr_startpoint(the_geom)) as source_y from ' || 
            quote_ident(geom_table) || ' where source = ' || 
            sourceid ||  ' or target='||sourceid||' limit 1'
        LOOP
    END LOOP;

    source_y := rec.source_y;

    FOR rec IN EXECUTE 
            'select st_x(pgr_startpoint(the_geom)) as target_x from ' ||
            quote_ident(geom_table) || ' where source = ' || 
            targetid ||  ' or target='||targetid||' limit 1'
        LOOP
    END LOOP;

    target_x := rec.target_x;
    
    FOR rec IN EXECUTE 
            'select st_y(pgr_startpoint(the_geom)) as target_y from ' || 
            quote_ident(geom_table) || ' where source = ' || 
            targetid ||  ' or target='||targetid||' limit 1'
        LOOP
    END LOOP;
    target_y := rec.target_y;


    FOR rec IN EXECUTE 'SELECT CASE WHEN '||source_x||'<'||target_x||
           ' THEN '||source_x||' ELSE '||target_x||
           ' END as ll_x, CASE WHEN '||source_x||'>'||target_x||
           ' THEN '||source_x||' ELSE '||target_x||' END as ur_x'
        LOOP
    END LOOP;

    ll_x := rec.ll_x;
    ur_x := rec.ur_x;

    FOR rec IN EXECUTE 'SELECT CASE WHEN '||source_y||'<'||
            target_y||' THEN '||source_y||' ELSE '||
            target_y||' END as ll_y, CASE WHEN '||
            source_y||'>'||target_y||' THEN '||
            source_y||' ELSE '||target_y||' END as ur_y'
        LOOP
    END LOOP;

    ll_y := rec.ll_y;
    ur_y := rec.ur_y;

    query := 'SELECT id,the_geom FROM ' || 
          'shortest_path_astar(''SELECT id as id, source::integer, ' || 
          'target::integer, '||cost||'::double precision as cost, ' || 
          'x1::double precision, y1::double precision, x2::double ' ||
          'precision, y2::double precision ';
    
    IF rc THEN query := query || ' , reverse_cost ';
    END IF;
      
    query := query || 'FROM ' || quote_ident(geom_table) || 
          ' where st_setSRID(''''BOX3D('||
          ll_x-delta||' '||ll_y-delta||','||ur_x+delta||' '||
          ur_y+delta||')''''::BOX3D, ' || srid || ') && the_geom'', ' || 
          quote_literal(sourceid) || ' , ' || 
          quote_literal(targetid) || ' , '''||
          text(dir)||''', '''||text(rc)||''' ),' || 
          quote_ident(geom_table) || ' where edge_id = id ';
    
    FOR path_result IN EXECUTE query
        LOOP

         geom.gid      := path_result.id;
         geom.the_geom := path_result.the_geom;
         id            := id+1;
         geom.id       := id;
                 
         RETURN NEXT geom;

    END LOOP;
    RETURN;
END;
$$
LANGUAGE 'plpgsql' VOLATILE STRICT; 


-----------------------------------------------------------------------
-- A-Star function for directed graphs.
-- Compute the shortest path using edges table, and return
-- the result as a set of (gid integer, the_geom geometry) records.
-- Also data clipping added to improve function performance.
--
-- Parameters: geom_table  : Table Name
--             sourcept    : Source XY (i.e. 'POINT(135 35)' )
--             targetpt    : Target XY (i.e. 'POINT(136 36)' )
--             cost        : Cost Column
--             delta       : search boundary offset in map units
--             dir         : Directed Search  (true/false)
--             rc          : Has Reverse Cost (true/false)
--
-- Last changes: July 1, 2012
-----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pgr_astar_sp_clip(
       geom_table varchar, sourcept varchar, targetpt varchar, 
       cost varchar, delta float8, dir boolean, rc boolean) 
       RETURNS SETOF GEOMS AS
$$
DECLARE 
    rec         record;
    path_result record;
    
    sourceid integer;
    targetid integer;
    id       integer;
    
    geom geoms;
    query text;
BEGIN
    
    id :=0;
    
    FOR rec IN EXECUTE
            'select find_nearest_node_within_distance(''' ||
            sourcept || ''','|| delta || ',''' || geom_table || ''')' ||
            ' as sourceid'
         LOOP
    END LOOP;
    
    IF rec IS NULL THEN
        RETURN;
    END IF;
    
    sourceid := rec.sourceid;
    
    FOR rec IN EXECUTE
            'select find_nearest_node_within_distance(''' ||
            targetpt || ''','|| delta || ',''' || geom_table || ''')' ||
            ' as targetid'
         LOOP
    END LOOP;
    
    IF rec IS NULL THEN
        RETURN;
    END IF;
    
    targetid := rec.targetid;

    query := 'select * from pgr_astar_sp_clip('''||geom_table||''','||
        sourceid||','||targetid||','''||cost||''','||delta||','||
        dir||','||rc||')';

    FOR path_result IN EXECUTE query
        LOOP

         geom.gid      := path_result.id;
         geom.the_geom := path_result.the_geom;
         id            := id+1;
         geom.id       := id;
                 
         RETURN NEXT geom;

    END LOOP;
    RETURN;
END;
$$
LANGUAGE 'plpgsql' VOLATILE STRICT; 


-------------------------------------------------------------
--  Creates a driving distance polygon using st_concavehull
--
-- Parameters: geom_table   : Table Name
--             x            : X Coordiante Point
--             y            : Y Coordinate Point
--             distance     : Distance of Search
--             cost         : Cost Column
--             reverse_cost : Reverse Cost Column 
--             dir          : Directed Search  (true/false)
--             rc           : Has Reverse Cost (true/false)
--             target_pct   : Concave Hull Target Percent (0.9 is safe)
--             holes        : Concave Hull Has Holes
--
-- Last changes: July 1, 2012
-------------------------------------------------------------
CREATE OR REPLACE FUNCTION pgr_driving_distance( 
    geom_table varchar, 
    x double precision, 
    y double precision, 
    distance double precision, 
    cost varchar, 
    reverse_cost varchar, 
    dir boolean, 
    rc boolean,
    target_pct double precision, 
    holes boolean)
       
   RETURNS SETOF GEOMS AS
$$
DECLARE
     q       text;
     
     srid    integer;
     node_id integer;    
     
     r       record;
     geom    geoms;
BEGIN
     
     FOR r IN EXECUTE 'SELECT srid FROM geometry_columns '||
        'WHERE f_table_name = '''  ||geom_table||'''' LOOP
     END LOOP;
     
     srid := r.srid;
     
     FOR r in EXECUTE 'SELECT id FROM '||
        'find_node_by_nearest_link_within_distance'||
        '(''POINT('||x||' '||y||')'','||distance/10||
        ','''||geom_table||''')' LOOP
     END LOOP;
     
     node_id := r.id;
      
    q := 'select st_concavehull(st_collect('||
         'st_startpoint(st_geometryn(the_geom,1))),'|| target_pct ||
         ','|| holes ||') as the_geom from ' || geom_table ||
         ',driving_distance(''SELECT id,source,target,cost,reverse_cost '||
         'from '|| geom_table|| ' where st_setsrid(''''BOX3D(' ||
         x-distance ||' '||y-distance||','||x+distance||' '||y+distance|| 
         ')''''::BOX3D,4326) && the_geom'','||node_id||','||distance/10||
         ','|| dir || ',' || rc ||') where edge_id = id';
 
     --RAISE NOTICE 'Query: %', q;
     
     FOR r IN EXECUTE q LOOP     
        geom.gid      := 1;
        geom.id       := 1;
        geom.the_geom := r.the_geom;
        RETURN NEXT geom;
     END LOOP;
     
     RETURN;

END;
$$
LANGUAGE 'plpgsql' VOLATILE STRICT;

       