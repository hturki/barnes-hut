import "regent"

local c = regentlib.c
local cos = regentlib.cos(float)
local sin = regentlib.sin(float)
local sqrt = regentlib.sqrt(float)

local cmath = terralib.includec("math.h")
local cstring = terralib.includec("string.h")
local std = terralib.includec("stdlib.h")

rawset(_G, "drand48", std.drand48)
rawset(_G, "srand48", std.srand48)

local gee = 100
local sector_precision = 16

struct Config {
  num_bodies : uint,
  random_seed : uint,
  iterations: uint
}

fspace sector {
  x: uint,
  y: uint
}

fspace body {
  x: double,
  y: double,
  x_speed: double,
  y_speed: double,
  mass: double,
  index: uint,
  sector: int2d
}

fspace boundary {
  min_x: double,
  min_y: double,
  max_x: double,
  max_y: double
}

struct quad_str {
  mass_x: double,
  mass_y: double,
  mass: double,
  total: uint,
  ne: &quad_str,
  nw: &quad_str,
  se: &quad_str,
  sw: &quad_str

  center_x: double,
  center_y: double,
  size: double,

  type: uint
}

terra parse_input_args(conf : Config)
  var args = c.legion_runtime_get_input_args()
  for i = 0, args.argc do
    if cstring.strcmp(args.argv[i], "-b") == 0 then
      i = i + 1
      conf.num_bodies = std.atoi(args.argv[i])
    elseif cstring.strcmp(args.argv[i], "-s") == 0 then
      i = i + 1
      conf.random_seed = std.atoi(args.argv[i])
    elseif cstring.strcmp(args.argv[i], "-i") == 0 then
      i = i + 1
      conf.iterations = std.atoi(args.argv[i])
    end
  end
  return conf
end

task init_black_hole(bodies : region(ispace(ptr), body), mass : uint, cx : double, cy : double, sx : double, sy : double, index: uint)
  where writes(bodies)
do
  bodies[index] = { x = cx, y = cy, x_speed = sx, y_speed = sy, mass = mass, index = index, sector = {x = 0, y = 0} }
end

task init_star(bodies : region(ispace(ptr), body), num : uint, max_radius : double, cx : double, cy : double, sx : double, sy : double, index: uint)
  where writes(bodies)
do
  var total_m = 1.5 * num
  var cube_max_radius = max_radius * max_radius * max_radius
  
  var angle = drand48() * 2 * cmath.M_PI
  var radius = 25 + max_radius * drand48()
  var x_star = cx + radius * sin(angle)
  var y_star = cy + radius * cos(angle)
  var speed = sqrt(gee * num / radius + gee * total_m * radius * radius / cube_max_radius)
  var x_speed_star = sx + speed * sin(angle + cmath.M_PI / 2)
  var y_speed_star = sy + speed * cos(angle + cmath.M_PI / 2)
  var mass_star = 1.0 + drand48()
  bodies[index] = { x = x_star, y = y_star, x_speed = x_speed_star, y_speed = y_speed_star, mass = mass_star, index = index, sector = {x = 0, y = 0} }
end

task init_2_galaxies(bodies : region(body), conf : Config)
  where writes(bodies)
do
  srand48(conf.random_seed)

  var bodies_partition = partition(equal, bodies, ispace(ptr, conf.num_bodies))

  var num1 = conf.num_bodies / 8
  init_black_hole(bodies_partition[0], num1, 0, 0, 0, 0, 0)
  
  __demand(__parallel)
  for i = 1, num1 do
    init_star(bodies_partition[i], num1, 300, 0, 0, 0, 0, i)
  end

  var num2 = conf.num_bodies / 8 * 7
  init_black_hole(bodies_partition[num1], num2, -1800, -1200, 0, 0, num1)
  
  __demand(__parallel)
  for i = num1 + 1, num1 + num2 do
    init_star(bodies_partition[i], num2, 350, -1800, -1200, 0, 0, i)
  end

end

task print_bodies_initial(bodies : region(body))
  where reads(bodies)
do
  c.printf("Initial bodies:\n") 
  for body in bodies do
    c.printf("%d: x: %f, y: %f, x_speed: %f, y_speed: %f, mass: %f\n",
    body.index, body.x, body.y, body.x_speed, body.y_speed, body.mass) 
  end
  c.printf("\n") 
end

local terra add_fork(from_x: double, from_y: double, size: double, cur: quad_str, body: quad_str): quad_str
  if cur.type == 0 then
    return body
  elseif cur.type == 1 then
    var center_x = from_x + cur.size / 2
    var center_y = from_y + cur.size / 2
    var fork : quad_str
    fork.center_x = center_x
    fork.center_y = center_y
    fork.size = size
    fork.type = 2
    fork.ne = nil
    fork.nw = nil
    fork.se = nil
    fork.sw = nil
    return add_fork(from_x, from_y, size, add_fork(from_x, from_y, size, fork, cur), body)
  elseif cur.type == 2 then
    var half_size = size / 2
    if body.mass_x <= cur.center_x then
      if body.mass_y <= cur.center_y then
        if body.nw == nil then
          body.nw = &body
        else
          var result = add_fork(from_x, from_y, half_size, @body.nw, body)
          body.nw = &result
        end
      else
        if body.sw == nil then
          body.sw = &body
        else
          var result = add_fork(from_x, cur.center_y, half_size, @body.sw, body)
          body.sw = &result
        end      
      end
    else
      if body.mass_y <= cur.center_y then
        if body.ne == nil then
          body.ne = &body
        else
          var result = add_fork(cur.center_x, from_y, half_size, @body.ne, body)
          body.ne = &result
        end
      else
        if body.se == nil then
          body.se = &body
        else
          var result = add_fork(cur.center_x, cur.center_y, half_size, @body.se, body)
          body.se = &result
        end      
      end
    end
  end

  return body
end

task build_quad(bodies: region(body), sector: int2d, from_x: double, from_y: double, sector_size: double)
  where
  reads(bodies.{x, y, mass})
do
  var root : quad_str
  root.total = 0
  for body in bodies do
    var body_str : quad_str
    body_str.mass_x = body.x
    body_str.mass_y = body.y
    body_str.mass = body.mass
    body_str.total = 1 
    body_str.type = 1   
    root = add_fork(from_x, from_y, sector_size, root, body_str)
  end
end

task assign_sectors(bodies: region(body), min_x: double, min_y: double, size_x: double, size_y: double)
  where
  reads(bodies.{x, y, sector, index}),
  writes(bodies.sector)
do
  for body in bodies do
    var sector_x: int64 = cmath.floor((body.x - min_x) / size_x)
    if (sector_x >= sector_precision) then
      sector_x = sector_x - 1
    end

    var sector_y: int64 = cmath.floor((body.y - min_y) / size_y)
    if (sector_y >= sector_precision) then
      sector_y = sector_y - 1
    end

    body.sector = { x = sector_x , y = sector_y }

    c.printf("x: %d, y: %d\n", sector_x, sector_y)
  end
end

task update_boundaries(bodies: region(body), boundaries: region(boundary))
  where
  reads(bodies.{x, y}),
  reads(boundaries),
  reduces min(boundaries.{min_x, min_y}),
  reduces max(boundaries.{max_x, max_y})
do
  for body in bodies do
    boundaries[0].min_x min = min(body.x, boundaries[0].min_x)
    boundaries[0].min_y min = min(body.y, boundaries[0].min_y)
    boundaries[0].max_x max = max(body.x, boundaries[0].max_x)
    boundaries[0].max_y max = max(body.y, boundaries[0].max_y)
  end
end

task run_iteration(bodies : region(body), body_index : ispace(ptr))
  where
  reads(bodies),
  writes(bodies.sector)
do
  var boundaries_index = ispace(ptr, 1)
  var boundaries = region(boundaries_index, boundary) 
  boundaries[0] = { min_x = bodies[0].x, min_y = bodies[0].y, max_x = bodies[0].x, max_y = bodies[0].y }
  
  var bodies_partition = partition(equal, bodies, body_index)
  for i in body_index do
    update_boundaries(bodies_partition[i], boundaries)
  end

  c.printf("boundaries: min_x=%f min_y=%f max_x=%f max_y=%f\n", boundaries[0].min_x, boundaries[0].min_y, boundaries[0].max_x, boundaries[0].max_y)

  var size_x = (boundaries[0].max_x - boundaries[0].min_x) / sector_precision
  var size_y = (boundaries[0].max_y - boundaries[0].min_y) / sector_precision

  for i in body_index do
    assign_sectors(bodies_partition[i], boundaries[0].min_x, boundaries[0].min_y, size_x, size_y)
  end

  var sector_index = ispace(int2d, { x = sector_precision, y = sector_precision })
  
  var child_index = ispace(int2d, { x = 2, y = 2 })

  var bodies_by_sector = partition(bodies.sector, sector_index)
  c.printf("\n")
  for i in bodies_by_sector.colors do
    build_quad(bodies_by_sector[i], i, 1, 1, 1)
  end
end

task main()
  var conf : Config
  conf.num_bodies = 16
  conf.random_seed = 213
  conf.iterations = 5

  conf = parse_input_args(conf)
  c.printf("circuit settings: bodies=%d seed=%d\n", conf.num_bodies, conf.random_seed) 

  var body_index = ispace(ptr, conf.num_bodies)
  var bodies = region(body_index, body)

  init_2_galaxies(bodies, conf)

  print_bodies_initial(bodies)

  run_iteration(bodies, body_index)
  
end
regentlib.start(main)