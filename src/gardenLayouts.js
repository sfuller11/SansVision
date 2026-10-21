// Where each spot sits in a garden picture (x and y are fractions of the picture; y is where the pot's base touches).
// The ids must match the garden_spots table in migration 11. Skins (night, autumn, desert) share their base garden's layout.
export const LAYOUTS = {
 "greenhouse": [
  {
   "id": "shelf1",
   "x": 0.1562,
   "y": 0.4367,
   "size": "S"
  },
  {
   "id": "shelf2",
   "x": 0.3275,
   "y": 0.4367,
   "size": "S"
  },
  {
   "id": "shelf3",
   "x": 0.5875,
   "y": 0.4367,
   "size": "S"
  },
  {
   "id": "shelf4",
   "x": 0.835,
   "y": 0.4367,
   "size": "S"
  },
  {
   "id": "bench1",
   "x": 0.2313,
   "y": 0.6533,
   "size": "M"
  },
  {
   "id": "bench2",
   "x": 0.5312,
   "y": 0.6533,
   "size": "M"
  },
  {
   "id": "bench3",
   "x": 0.7688,
   "y": 0.6533,
   "size": "M"
  },
  {
   "id": "floor1",
   "x": 0.1313,
   "y": 0.8833,
   "size": "L"
  },
  {
   "id": "floor2",
   "x": 0.4375,
   "y": 0.9,
   "size": "L"
  },
  {
   "id": "floor3",
   "x": 0.8125,
   "y": 0.875,
   "size": "L"
  }
 ],
 "backyard": [
  {
   "id": "bench1",
   "x": 0.7375,
   "y": 0.5583,
   "size": "S"
  },
  {
   "id": "bench2",
   "x": 0.875,
   "y": 0.5633,
   "size": "S"
  },
  {
   "id": "bed1",
   "x": 0.115,
   "y": 0.6533,
   "size": "M"
  },
  {
   "id": "bed2",
   "x": 0.2375,
   "y": 0.6633,
   "size": "M"
  },
  {
   "id": "bed3",
   "x": 0.36,
   "y": 0.65,
   "size": "M"
  },
  {
   "id": "barrow",
   "x": 0.5975,
   "y": 0.7417,
   "size": "M"
  },
  {
   "id": "stump",
   "x": 0.4525,
   "y": 0.72,
   "size": "M"
  },
  {
   "id": "ground1",
   "x": 0.15,
   "y": 0.9083,
   "size": "L"
  },
  {
   "id": "ground2",
   "x": 0.5025,
   "y": 0.93,
   "size": "L"
  },
  {
   "id": "ground3",
   "x": 0.835,
   "y": 0.87,
   "size": "L"
  }
 ],
 "balcony": [
  {
   "id": "rail1",
   "x": 0.2125,
   "y": 0.5033,
   "size": "S"
  },
  {
   "id": "rail2",
   "x": 0.7,
   "y": 0.51,
   "size": "S"
  },
  {
   "id": "hang1",
   "x": 0.4125,
   "y": 0.2967,
   "size": "S"
  },
  {
   "id": "hang2",
   "x": 0.8125,
   "y": 0.32,
   "size": "S"
  },
  {
   "id": "crate1",
   "x": 0.3125,
   "y": 0.7,
   "size": "M"
  },
  {
   "id": "crate2",
   "x": 0.6,
   "y": 0.76,
   "size": "M"
  },
  {
   "id": "floor",
   "x": 0.45,
   "y": 0.92,
   "size": "L"
  }
 ],
 "rocks": [
  {
   "id": "ledge1",
   "x": 0.1875,
   "y": 0.4367,
   "size": "S"
  },
  {
   "id": "ledge2",
   "x": 0.39,
   "y": 0.4467,
   "size": "S"
  },
  {
   "id": "boulder1",
   "x": 0.715,
   "y": 0.5367,
   "size": "M"
  },
  {
   "id": "boulder2",
   "x": 0.115,
   "y": 0.62,
   "size": "M"
  },
  {
   "id": "boulder3",
   "x": 0.4225,
   "y": 0.6833,
   "size": "M"
  },
  {
   "id": "gravel1",
   "x": 0.605,
   "y": 0.7633,
   "size": "M"
  },
  {
   "id": "gravel2",
   "x": 0.265,
   "y": 0.7867,
   "size": "M"
  },
  {
   "id": "front1",
   "x": 0.1375,
   "y": 0.9083,
   "size": "L"
  },
  {
   "id": "front2",
   "x": 0.5275,
   "y": 0.92,
   "size": "L"
  },
  {
   "id": "front3",
   "x": 0.865,
   "y": 0.8833,
   "size": "L"
  }
 ],
 "courtyard": [
  {
   "id": "wall1",
   "x": 0.1625,
   "y": 0.4367,
   "size": "S"
  },
  {
   "id": "wall2",
   "x": 0.4775,
   "y": 0.43,
   "size": "S"
  },
  {
   "id": "wall3",
   "x": 0.765,
   "y": 0.4433,
   "size": "S"
  },
  {
   "id": "left1",
   "x": 0.0875,
   "y": 0.5933,
   "size": "M"
  },
  {
   "id": "left2",
   "x": 0.2375,
   "y": 0.62,
   "size": "M"
  },
  {
   "id": "right1",
   "x": 0.8,
   "y": 0.5833,
   "size": "M"
  },
  {
   "id": "right2",
   "x": 0.9275,
   "y": 0.6067,
   "size": "M"
  },
  {
   "id": "stone1",
   "x": 0.415,
   "y": 0.72,
   "size": "S"
  },
  {
   "id": "stone2",
   "x": 0.5275,
   "y": 0.79,
   "size": "S"
  },
  {
   "id": "stone3",
   "x": 0.6325,
   "y": 0.7067,
   "size": "S"
  },
  {
   "id": "front1",
   "x": 0.1875,
   "y": 0.9367,
   "size": "L"
  },
  {
   "id": "front2",
   "x": 0.8275,
   "y": 0.9433,
   "size": "L"
  }
 ]
};

// Garden types in the same order as the database. "layout" picks the spots, the id picks the picture in /public/gardens.
export const gardenImg = (typeId) => `/gardens/${typeId}.png`;
// Width of a plant picture as a share of the garden picture.
export const SIZE_W = { S: 0.136, M: 0.168, L: 0.208 };
export const SIZE_LABEL = { S: "small", M: "medium", L: "large" };
