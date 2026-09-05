import { Component } from '@angular/core'

@Component({
  selector: 'app-root',
  template: '<h1>{{ title }}</h1>',
})
export class AppComponent {
  title = 'fixture'

  rename(next: string): void {
    this.title = next
  }
}
