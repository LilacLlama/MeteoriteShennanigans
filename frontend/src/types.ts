export interface MeteoritePoint {
  id: number;
  name: string;
  reclat: number;
  reclong: number;
  recclass: string | null;
  mass_g: number | null;
  year: number | null;
  fall: string | null;
}

export interface MeteoriteDetail extends MeteoritePoint {
  nametype: string | null;
}
