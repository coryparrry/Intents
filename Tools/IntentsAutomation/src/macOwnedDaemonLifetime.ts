/** Owns startup through termination, including stop before or during asynchronous creation. */
export class MacOwnedDaemonLifetime<T> {
  private started=false;
  private closing=false;
  private startup:Promise<T>|undefined;
  private value:T|undefined;
  private stopping:Promise<unknown>|undefined;
  constructor(private dispose:(value:T)=>Promise<unknown>){}
  get canStart(){return !this.started && !this.closing;}
  get active(){return !this.closing && this.value!==undefined;}
  async start(factory:()=>Promise<T>):Promise<T>{
    if(this.started || this.closing)throw new Error('Private daemon lifetime unavailable');
    this.started=true;
    this.startup=Promise.resolve().then(factory).then(value=>{this.value=value;return value;});
    const value=await this.startup;
    if(this.closing){await this.stop();throw new Error('Private daemon startup was stopped');}
    return value;
  }
  stop():Promise<unknown>{
    this.closing=true;
    return this.stopping??=this.finish();
  }
  private async finish():Promise<unknown>{
    if(this.startup){try{await this.startup;}catch{return {resourcesReleased:false};}}
    return this.value===undefined?{resourcesReleased:!this.started}:await this.dispose(this.value);
  }
}
