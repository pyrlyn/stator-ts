interface UserConfig {
  name?: string;
}
interface Starred {
  a: number;
}
declare const config: UserConfig;
export { type UserConfig, type Starred as Renamed, config };
