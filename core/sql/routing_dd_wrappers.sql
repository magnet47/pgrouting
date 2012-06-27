--
-- Copyright (c) 2005 Sylvain Pasche,
--               2006-2007 Anton A. Patrushev, Orkney, Inc.
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

-------------------------------------------------------------
--  Creates a driving distance polygon using st_concavehull
--                 last change: Jun-19-2012
-------------------------------------------------------------
CREATE OR REPLACE FUNCTION driving_distance( table_name varchar, 
   x double precision, y double precision, distance double precision, 
   cost varchar, reverse_cost varchar, 
   directed boolean, has_reverse_cost boolean,
   target_percent double precision, has_holes boolean)
       RETURNS SETOF GEOMS AS
$$
DECLARE
     q       text;
     qq      text;     
     srid    integer;
     node_id integer;    
     r       record;
     geom geoms;
BEGIN
     
     FOR r IN EXECUTE 'SELECT srid FROM geometry_columns WHERE f_table_name = '''
        ||table_name||'''' LOOP
     END LOOP;
     
     srid := r.srid;
     
     --RAISE NOTICE 'SRID: %', srid;

     FOR r in EXECUTE 'SELECT id FROM find_node_by_nearest_link_within_distance'||
       '(''POINT('||x||' '||y||')'','||distance/10||','''||table_name||''')' LOOP
     END LOOP;
     
     node_id := r.id;
      
     --qq := '''srid='||srid||';POLYGON(('||x-distance||' '||y-distance
     --             ||','||x-distance||' '||y+distance
     --             ||','||x+distance||' '||y+distance
     --             ||','||x+distance||' '||y-distance
     --             ||','||x-distance||' '||y-distance||'))''';
        
     --q := 'select 1 as id,st_concavehull(st_collect('
     --     ||'st_startpoint(st_geometryn(the_geom,1))),'
     --     || target_percent ||','|| has_holes ||') as the_geom '
     --     ||'from '|| table_name ||',driving_distance('
     --     ||'''SELECT id,source,target,cost,reverse_cost from '
     --     || table_name ||' where st_contains(ST_GeomFromEWKT('''
     --     || qq ||'''),the_geom) = true'','
     --     || node_id ||','|| distance/10 ||','
     --     || directed ||','
     --     || has_reverse_cost || ') where edge_id = id';
      
    q := 'select st_concavehull(st_collect('||
         'st_startpoint(st_geometryn(the_geom,1))),'||target_percent||
         ','|| has_holes ||') as the_geom from ' || table_name ||
         ',driving_distance(''SELECT id,source,target,cost,reverse_cost '||
         'from '|| table_name|| ' where st_setsrid(''''BOX3D(' ||
         x-distance ||' '||y-distance||','||x+distance||' '||y+distance|| 
         ')''''::BOX3D,4326) && the_geom'','||node_id||','||distance/10||
         ','||directed || ',' || has_reverse_cost ||') where edge_id = id';
 
     RAISE NOTICE 'Query: %', q;
     
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

-- COMMIT;
